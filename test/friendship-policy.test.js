'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const privacy = require('../server/contact-phone-privacy');
const friendship = require('../server/friendship-policy');
const { queueContactRequest, REQUEST_SCHEMA } = require('../server/contact-message-requests');

test('friendship, group phone choices and marketplace delivery use server-owned relationships',
  { skip: process.env.RUN_DB_TESTS !== '1' }, async t => {
  const { Client } = require('pg');
  const db = new Client({connectionString:process.env.DATABASE_URL});
  await db.connect();
  const [buyer,seller,outsider,listing,group] = Array.from({length:5},randomUUID);
  try {
    await db.query('BEGIN');
    await db.query(`CREATE TEMP TABLE users(id uuid PRIMARY KEY,phone text,birth_date date,name text,gender text,email_verified boolean,phone_verified boolean);
      CREATE TEMP TABLE user_contacts(owner_id uuid,contact_id uuid,PRIMARY KEY(owner_id,contact_id));
      CREATE TEMP TABLE blocked_users(blocker_id uuid,blocked_id uuid);
      CREATE TEMP TABLE group_members(user_id uuid,group_id uuid,status text);
      CREATE TEMP TABLE listings(id uuid PRIMARY KEY,user_id uuid,status text,contact_count integer DEFAULT 0,expires_at timestamptz,contact_preferences jsonb);
      CREATE TEMP TABLE listing_conversations(buyer_id uuid REFERENCES users,seller_id uuid REFERENCES users,
        listing_id uuid REFERENCES listings,inquiry_sent boolean DEFAULT FALSE,created_at timestamptz DEFAULT now(),PRIMARY KEY(buyer_id,seller_id));
      CREATE TEMP TABLE message_requests(id uuid DEFAULT gen_random_uuid(),sender_id uuid,recipient_id uuid,body text,type text,file_url text,file_name text,
        audit_operation_id uuid,audit_parent_event_id bigint,created_at timestamptz DEFAULT now());
      CREATE TEMP TABLE contact_phone_permissions(phone_owner_id uuid REFERENCES users,viewer_id uuid REFERENCES users,state text,
        phone_hash text,requested_at timestamptz,updated_at timestamptz DEFAULT now(),PRIMARY KEY(phone_owner_id,viewer_id));`);
    await db.query('SET LOCAL search_path=pg_temp,public');
    await db.query(`INSERT INTO users VALUES($1,'0501111111','1990-01-01','buyer','male',TRUE,FALSE),
      ($2,'0502222222','1990-01-01','seller','male',TRUE,FALSE),($3,'0503333333','1990-01-01','other','male',TRUE,FALSE)`,[buyer,seller,outsider]);
    await db.query("INSERT INTO group_members VALUES($1,$3,'member'),($2,$3,'member')",[buyer,seller,group]);
    await privacy.initializePhonePrivacy(db);
    await friendship.initializeFriendshipPolicy(db);
    await db.query(REQUEST_SCHEMA);
    const phone = async (viewer=buyer,target=seller) => {
      const js = await privacy.getPhoneSharingStatus(db,viewer,target);
      const sql = (await db.query(`SELECT ${privacy.phoneSelect()} FROM users u WHERE u.id=$2`,[viewer,target])).rows[0];
      assert.equal(sql.phone,js.phone,'all API and guide projections agree'); return js;
    };
    await t.test('migration keeps existing group memberships private and defaults new membership to sharing',async()=>{
      assert.equal((await phone()).phone,null);
      assert.equal((await db.query('SELECT share_phone FROM group_members LIMIT 1')).rows[0].share_phone,false);
      await friendship.initializeFriendshipPolicy(db);
      assert.equal((await phone()).phone,null,'migration repeat must not opt existing members in');
      await db.query("INSERT INTO group_members(user_id,group_id,status) VALUES($1,$2,'member')",[outsider,group]);
      assert.equal((await phone(buyer,outsider)).phone,'0503333333');
      assert.equal((await phone(outsider,seller)).phone,null,'sharing is directed owner choice');
      await db.query('UPDATE group_members SET share_phone=TRUE WHERE user_id=$1',[seller]);
      assert.equal((await phone()).phone,'0502222222');
      await db.query("UPDATE group_members SET status='pending' WHERE user_id=$1",[buyer]);
      assert.equal((await phone()).phone,null,'pending viewers never see group numbers');
      await db.query("UPDATE group_members SET status='member',share_phone=FALSE WHERE user_id=ANY($1::uuid[])",[[buyer,seller,outsider]]);
    });
    await t.test('one-way save is private; mutual friendship shares both without approval',async()=>{
      await db.query("INSERT INTO user_contacts(owner_id,contact_id) VALUES($1,$2)",[buyer,seller]);
      assert.equal((await phone()).phone,null);
      await db.query("INSERT INTO user_contacts(owner_id,contact_id) VALUES($2,$1)",[buyer,seller]);
      assert.equal((await phone()).phone,'0502222222');
      assert.equal((await phone(seller,buyer)).phone,'0501111111');
      assert.equal((await phone()).is_friend,true);
      assert.equal((await phone()).can_request_phone,false);
      assert.equal((await phone(outsider,seller)).phone,null);
      await db.query('INSERT INTO blocked_users VALUES($1,$2)',[seller,buyer]);
      assert.equal((await phone()).phone,null);
      assert.equal((await phone(seller,buyer)).phone,null);
      await db.query('TRUNCATE blocked_users');
    });
    await t.test('disconnect removes both contacts and old grants, preserving separate group consent',async()=>{
      await privacy.applyPhoneSharingChoices(db,seller,buyer,{share_my_phone:true});
      await friendship.disconnectFriendship(db,buyer,seller);
      assert.equal((await db.query('SELECT * FROM user_contacts')).rows.length,0);
      assert.equal((await db.query('SELECT * FROM contact_phone_permissions')).rows.length,0);
      assert.equal((await phone()).phone,null);
      await db.query('UPDATE group_members SET share_phone=TRUE WHERE user_id=$1',[seller]);
      assert.equal((await phone()).phone,'0502222222');
      await db.query('UPDATE group_members SET share_phone=FALSE WHERE user_id=$1',[seller]);
      assert.equal((await friendship.disconnectFriendship(db,buyer,seller)),false,'idempotent');
    });
    await db.query("INSERT INTO listings(id,user_id,status) VALUES($1,$2,'active')",[listing,seller]);
    await t.test('listing opening is not friendship; inquiry bypasses acceptance and seller reply creates mutual friendship',async()=>{
      await friendship.registerListingInquiry(db,buyer,seller,listing);
      assert.equal(await friendship.marketplaceConversation(db,buyer,seller),true);
      assert.equal(await friendship.marketplaceConversation(db,seller,buyer),false,'reply needs a delivered inquiry');
      assert.equal((await phone()).phone,null);
      assert.equal(await queueContactRequest(db,{senderId:buyer,recipientId:seller,body:'inquiry',type:'text'}),null);
      assert.equal((await db.query('SELECT * FROM message_requests')).rows.length,0);
      assert.equal(await friendship.deliveredMarketplaceMessage(db,buyer,seller),false);
      assert.equal(await friendship.marketplaceConversation(db,seller,buyer),true);
      assert.equal((await phone()).is_friend,false);
      assert.equal(await friendship.deliveredMarketplaceMessage(db,seller,buyer),true);
      assert.equal((await phone()).is_friend,true);
      assert.equal((await phone(seller,buyer)).phone,'0501111111');
      assert.equal(await friendship.deliveredMarketplaceMessage(db,seller,buyer),false,'retries do not recreate friendship');
      await friendship.disconnectFriendship(db,buyer,seller);
      assert.equal(await friendship.marketplaceConversation(db,buyer,seller),false);
    });
    await t.test('forged listing recipient, blocked inquiry, and rolled back replies cannot establish friendship',async()=>{
      await db.query('SAVEPOINT wrong_target');
      await assert.rejects(friendship.registerListingInquiry(db,buyer,outsider,listing),{status:403});
      await db.query('ROLLBACK TO SAVEPOINT wrong_target');
      assert.equal(await friendship.marketplaceConversation(db,buyer,seller),false);
      await db.query('INSERT INTO blocked_users VALUES($1,$2)',[buyer,seller]);
      await assert.rejects(friendship.openListingConversation(db,buyer,listing),{status:403});
      await db.query('TRUNCATE blocked_users');
      await friendship.registerListingInquiry(db,buyer,seller,listing);
      await friendship.deliveredMarketplaceMessage(db,buyer,seller);
      await db.query('SAVEPOINT failed_reply');
      await assert.rejects(friendship.writeFriendshipMessage(db,seller,buyer,async()=>{throw Error('filtered');}),/filtered/);
      await db.query('ROLLBACK TO SAVEPOINT failed_reply');
      assert.equal((await phone()).is_friend,false);
      await db.query("UPDATE listings SET status='sold' WHERE id=$1",[listing]);
      await assert.rejects(friendship.openListingConversation(db,outsider,listing),{status:404});
    });
    await t.test('authenticated group sharing edits and reports cannot act on another user',async()=>{
      const source=require('node:fs').readFileSync(require.resolve('../server/index.js'),'utf8');
      const routes={};
      const scope={app:{put:(path,...handlers)=>routes[path]=handlers.at(-1),post:(path,...handlers)=>routes[path]=handlers.at(-1)},
        auth(){},authWithDbCheck(){},reportRateLimit(){},getPool:async()=>db,
        friendshipTransaction:friendship.transaction,disconnectFriendship:friendship.disconnectFriendship,
        notifyFriendshipChange(){},io:{to:()=>({emit(){}})},logActivity(){},clientIp:()=>'',runReportNotifications(){},console};
      const vm=require('node:vm');
      vm.runInNewContext(source.slice(source.indexOf("app.put('/api/groups/:id/phone-sharing'"),source.indexOf("app.get('/api/groups/:id/filter-settings'")),scope);
      vm.runInNewContext(source.slice(source.indexOf("app.post('/api/reports'"),source.indexOf('// ── Profile: get')),scope);
      const call=async(path,actor,body,groupId=group)=>{
        const res={code:200,set(){return this;},status(code){this.code=code;return this;},json(body){this.body=body;return this;}};
        await routes[path]({user:{id:actor},params:{id:groupId},body},res);return res;
      };
      const changed=await call('/api/groups/:id/phone-sharing',buyer,{share_phone:true,user_id:seller});
      assert.equal(changed.code,200);
      assert.equal((await phone(seller,buyer)).phone,'0501111111');
      assert.equal((await phone(buyer,seller)).phone,null,'supplied user_id cannot change another owner');
      assert.equal((await call('/api/groups/:id/phone-sharing',buyer,{share_phone:'false'})).code,400);
      await db.query("UPDATE group_members SET status='pending' WHERE user_id=$1",[outsider]);
      assert.equal((await call('/api/groups/:id/phone-sharing',outsider,{share_phone:true})).code,403);
      await db.query(`CREATE TEMP TABLE user_reports(id uuid DEFAULT gen_random_uuid(),reporter_id uuid,target_type text,target_id uuid,
        reason text,details text,status text DEFAULT 'pending',reviewed_by uuid,reviewed_at timestamptz,created_at timestamptz DEFAULT now(),
        notification_version integer DEFAULT 1,notification_attempts integer DEFAULT 0,notification_next_at timestamptz,notification_error text,
        UNIQUE(reporter_id,target_type,target_id));`);
      await db.query('INSERT INTO user_contacts(owner_id,contact_id) VALUES($1,$2),($2,$1)',[buyer,seller]);
      const reported=await call('/api/reports',buyer,{targetType:'user',targetId:seller,reason:'harassment',reporterId:outsider});
      assert.equal(reported.code,201);
      assert.equal((await phone()).is_friend,false);
      assert.equal((await db.query('SELECT reporter_id FROM user_reports')).rows[0].reporter_id,buyer);
      assert.equal((await db.query('SELECT * FROM user_contacts')).rows.length,0);
      assert.equal((await db.query('SELECT * FROM listing_conversations')).rows.length,0);
    });
  } finally { await db.query('ROLLBACK').catch(()=>{}); await db.end(); }
});
