'use strict';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function pair(a, b) {
  if (!UUID.test(a || '') || !UUID.test(b || '') || a === b)
    throw Object.assign(new Error('מזהי המשתמשים אינם תקינים'), { status: 400 });
}
function mutualFriendSql(viewer, target) {
  return `EXISTS (SELECT 1 FROM user_contacts f JOIN user_contacts r
    ON r.owner_id=f.contact_id AND r.contact_id=f.owner_id
    WHERE f.owner_id=${viewer} AND f.contact_id=${target})`;
}
function groupPhoneSql(viewer, target) {
  return `EXISTS (SELECT 1 FROM group_members mine JOIN group_members theirs
    ON theirs.group_id=mine.group_id WHERE mine.user_id=${viewer}
    AND theirs.user_id=${target} AND mine.status='member' AND theirs.status='member'
    AND theirs.share_phone=TRUE)`;
}
async function initializeFriendshipPolicy(db) {
  // Existing memberships retain their former privacy; only future membership
  // creation/join defaults to sharing. Re-running this migration is harmless.
  await db.query(`ALTER TABLE group_members ADD COLUMN IF NOT EXISTS share_phone BOOLEAN NOT NULL DEFAULT FALSE;
    ALTER TABLE group_members ALTER COLUMN share_phone SET DEFAULT TRUE;
    CREATE INDEX IF NOT EXISTS group_members_phone_idx ON group_members(user_id,group_id)
      WHERE status='member' AND share_phone=TRUE;
    CREATE TABLE IF NOT EXISTS listing_conversations (
      buyer_id UUID REFERENCES users(id) ON DELETE CASCADE,
      seller_id UUID REFERENCES users(id) ON DELETE CASCADE,
      listing_id UUID REFERENCES listings(id) ON DELETE CASCADE,
      inquiry_sent BOOLEAN NOT NULL DEFAULT FALSE,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY(buyer_id,seller_id), CHECK(buyer_id<>seller_id));`);
}
async function lockFriendship(db, a, b) {
  pair(a, b);
  await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',
    [`friendship:${[a, b].sort().join(':')}`]);
}
async function marketplaceConversation(db, a, b) {
  const result = await db.query(`SELECT 1 FROM listing_conversations lc
    WHERE ((lc.buyer_id=$1 AND lc.seller_id=$2) OR
      (lc.buyer_id=$2 AND lc.seller_id=$1 AND lc.inquiry_sent=TRUE))
    AND NOT EXISTS(SELECT 1 FROM blocked_users WHERE
      (blocker_id=$1 AND blocked_id=$2) OR (blocker_id=$2 AND blocked_id=$1))`, [a,b]);
  return result.rows.length > 0;
}
async function openListingConversation(db, buyer, listingId) {
  if (!UUID.test(listingId || '')) throw Object.assign(new Error('מזהה המודעה אינו תקין'), { status: 400 });
  const listing = (await db.query(`SELECT l.user_id FROM listings l JOIN users u ON u.id=$2
    WHERE l.id=$1 AND l.status='active' AND (l.expires_at IS NULL OR l.expires_at>now())
    AND COALESCE((l.contact_preferences->>'in_app')::boolean,TRUE) AND u.birth_date<=CURRENT_DATE-INTERVAL '18 years'`, [listingId,buyer])).rows[0];
  if (!listing) throw Object.assign(new Error('המודעה אינה זמינה לפנייה'), { status: 404 });
  const seller = listing.user_id;
  pair(buyer, seller);
  await lockFriendship(db, buyer, seller);
  const blocked = await db.query(`SELECT 1 FROM blocked_users WHERE
    (blocker_id=$1 AND blocked_id=$2) OR (blocker_id=$2 AND blocked_id=$1)`, [buyer,seller]);
  if (blocked.rows.length) throw Object.assign(new Error('לא ניתן לפנות למשתמש זה'), { status: 403 });
  await db.query(`INSERT INTO listing_conversations(buyer_id,seller_id,listing_id)
    VALUES($1,$2,$3) ON CONFLICT(buyer_id,seller_id) DO UPDATE SET listing_id=EXCLUDED.listing_id`, [buyer,seller,listingId]);
  await db.query('UPDATE listings SET contact_count=contact_count+1 WHERE id=$1', [listingId]);
  return seller;
}
// Called inside the transaction that actually persists the approved message.
// Merely opening a listing or uploading/rejecting a file never creates friends.
async function deliveredMarketplaceMessage(db, sender, recipient) {
  if (sender === recipient) return false;
  await lockFriendship(db,sender,recipient);
  const channel = (await db.query(`SELECT * FROM listing_conversations
    WHERE (buyer_id=$1 AND seller_id=$2) OR (buyer_id=$2 AND seller_id=$1)
    ORDER BY (seller_id=$1 AND inquiry_sent) DESC
    FOR UPDATE`, [sender,recipient])).rows[0];
  if (!channel) return false;
  if (!await marketplaceConversation(db,sender,recipient))
    throw Object.assign(new Error('הגישה לשיחת המודעה השתנתה'), { status: 403 });
  if (channel.buyer_id === sender) {
    await db.query('UPDATE listing_conversations SET inquiry_sent=TRUE WHERE buyer_id=$1 AND seller_id=$2', [sender,recipient]);
    return false;
  }
  if (!channel.inquiry_sent) return false;
  await db.query(`INSERT INTO user_contacts(owner_id,contact_id,contact_source)
    VALUES($1,$2,'in_app'),($2,$1,'in_app') ON CONFLICT(owner_id,contact_id) DO NOTHING`, [sender,recipient]);
  await db.query(`DELETE FROM listing_conversations WHERE buyer_id=$1 AND seller_id=$2`, [recipient,sender]);
  return true;
}
async function disconnectFriendship(db, actor, target) {
  await lockFriendship(db,actor,target);
  const removed = await db.query(`DELETE FROM user_contacts WHERE
    (owner_id=$1 AND contact_id=$2) OR (owner_id=$2 AND contact_id=$1)`, [actor,target]);
  await db.query(`DELETE FROM contact_phone_permissions WHERE
    (phone_owner_id=$1 AND viewer_id=$2) OR (phone_owner_id=$2 AND viewer_id=$1)`, [actor,target]);
  await db.query(`DELETE FROM listing_conversations WHERE
    (buyer_id=$1 AND seller_id=$2) OR (buyer_id=$2 AND seller_id=$1)`, [actor,target]);
  return removed.rowCount > 0;
}
module.exports = { mutualFriendSql, groupPhoneSql, initializeFriendshipPolicy,
  marketplaceConversation, openListingConversation, deliveredMarketplaceMessage,
  disconnectFriendship, lockFriendship };

async function transaction(db, action) {
  if (!db.connect || db instanceof require('pg').Client) return action(db);
  const client = await db.connect();
  try { await client.query('BEGIN'); const result=await action(client);
    await client.query('COMMIT'); return result;
  } catch(error) { await client.query('ROLLBACK').catch(()=>{}); throw error; }
  finally { client.release(); }
}
async function registerListingInquiry(db, buyer, seller, listingId) {
  return transaction(db, async client => {
    const owner = await openListingConversation(client,buyer,listingId);
    if (owner !== seller) throw Object.assign(new Error('הנמען אינו מפרסם המודעה'), { status: 403 });
  });
}
async function writeFriendshipMessage(db,sender,recipient,write) {
  return transaction(db,async client => {
    if (sender !== recipient) await lockFriendship(client,sender,recipient);
    const result=await write(client);
    result.friendshipChanged=await deliveredMarketplaceMessage(client,sender,recipient);
    return result;
  });
}
module.exports.transaction=transaction;
module.exports.registerListingInquiry=registerListingInquiry;
module.exports.writeFriendshipMessage=writeFriendshipMessage;
