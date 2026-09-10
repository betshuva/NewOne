'use strict';
const { initializePhonePrivacy } = require('../server/contact-phone-privacy');
const test = require('node:test');
const assert = require('node:assert/strict');
const { executeGuideDataPlan } = require('../server/guide-user-data');
const plan = overrides => ({ action:'read', requests:[{
  kind:'members', group_query:'', group_scope:'all', contact_filter:'not_saved',
  fields:['name','groups','city'], format:'table', admins_only:false, ...overrides,
}] });

test('all-group comparison deduplicates authorized users and protects profile fields', {
  skip: process.env.RUN_DB_TESTS !== '1',
}, async t => {
  const {Client}=require('pg');
  const db=new Client({connectionString:process.env.DATABASE_URL,
    ssl:process.env.DB_SSL==='true'?{rejectUnauthorized:process.env.DB_REJECT_UNAUTHORIZED!=='false'}:false});
  const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
  const [me,saved,shared,sameName,blocked,reverseBlocked,pending,removed,outside,teen]=[501,502,503,504,505,506,507,508,509,510].map(id);
  const [alpha,beta,privateGroup,pendingGroup]=[601,602,603,604].map(id);
  await db.connect();
  try {
    await db.query('BEGIN');
    await db.query(`CREATE TEMP TABLE users(id uuid PRIMARY KEY,name text,phone text,city text,gender text,
      birth_date date,email_verified boolean DEFAULT false,phone_verified boolean DEFAULT false);
      CREATE TEMP TABLE groups(id uuid PRIMARY KEY,name text);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,status text,role text);
      CREATE TEMP TABLE user_contacts(owner_id uuid,contact_id uuid);
      CREATE TEMP TABLE blocked_users(blocker_id uuid,blocked_id uuid);
      CREATE TEMP TABLE messages(id uuid,sender_id uuid,recipient_id uuid,group_id uuid,
        deleted_for_everyone boolean DEFAULT false,deleted_for_sender boolean DEFAULT false);
      CREATE TEMP TABLE message_user_deletions(message_id uuid,user_id uuid);`);
    await db.query('SET LOCAL search_path TO pg_temp');
    await initializePhonePrivacy(db);
    const rows=[
      [me,'המבקש','1990-01-01','עיר המבקש'],[saved,'שם זהה','1990-01-01','ירושלים'],
      [shared,'משותף בשתי קבוצות','1990-01-01','חיפה'],[sameName,'שם זהה','1990-01-01','עיר חסויה'],
      [blocked,'חסום ממני','1990-01-01','מוסתר'],[reverseBlocked,'חסם אותי','1990-01-01','מוסתר'],
      [pending,'ממתין לאישור','1990-01-01','מוסתר'],[removed,'חבר שהוסר','1990-01-01','מוסתר'],
      [outside,'חבר בקבוצה פרטית','1990-01-01','מוסתר'],[teen,'חבר נוער','2015-01-01','עיר ישנה של קטין'],
    ];
    for (const row of rows) await db.query('INSERT INTO users(id,name,birth_date,city) VALUES($1,$2,$3,$4)',row);
    await db.query('UPDATE users SET email_verified=true,phone=$1 WHERE id=$2',['0501111111',shared]);
    await db.query('UPDATE users SET phone=$1 WHERE id=$2',['0502222222',sameName]);
    for (const [group,name] of [[alpha,'קבוצה א'],[beta,'קבוצה ב'],[privateGroup,'קבוצה נסתרת'],[pendingGroup,'קבוצה בהמתנה']])
      await db.query('INSERT INTO groups VALUES($1,$2)',[group,name]);
    for (const user of [me,saved,shared,sameName,blocked,reverseBlocked,teen])
      await db.query("INSERT INTO group_members VALUES($1,$2,'member',$3)",[alpha,user,user===me?'admin':'member']);
    for (const user of [me,shared,saved]) await db.query("INSERT INTO group_members VALUES($1,$2,'member','member')",[beta,user]);
    await db.query("INSERT INTO group_members VALUES($1,$2,'pending','member'),($1,$3,'removed','member')",[alpha,pending,removed]);
    await db.query("INSERT INTO group_members VALUES($1,$2,'member','admin'),($3,$4,'pending','member'),($3,$2,'member','member')",[privateGroup,outside,pendingGroup,me]);
    await db.query('INSERT INTO user_contacts VALUES($1,$2),($3,$1)',[me,saved,shared]);
    await db.query('INSERT INTO blocked_users VALUES($1,$2),($3,$1)',[me,blocked,reverseBlocked]);
    await t.test('noncontacts use owner IDs, unique users, active mutual groups and bilateral blocks',async()=>{
      const answer=await executeGuideDataPlan(db,me,plan());
      assert.match(answer,/\(3; כל אדם מופיע פעם אחת\)/);
      assert.equal(answer.split('משותף בשתי קבוצות').length-1,1);
      assert.equal(answer.split('שם זהה').length-1,1);
      assert.match(answer,/קבוצה א, קבוצה ב/);
      assert.match(answer,/חיפה/);
      assert.match(answer,/לא זמין להצגה/);
      assert.doesNotMatch(answer,/המבקש|ירושלים|עיר חסויה|עיר ישנה של קטין|קבוצה נסתרת|קבוצה בהמתנה|חסום ממני|חסם אותי|ממתין לאישור|חבר שהוסר/);
    });
    await t.test('count agrees with unique result rows, saved comparison has only own saved contacts',async()=>{
      assert.match(await executeGuideDataPlan(db,me,plan({format:'count'})),/: 3\. כל אדם נספר פעם אחת/);
      const answer=await executeGuideDataPlan(db,me,plan({contact_filter:'saved'}));
      assert.match(answer,/\(1; כל אדם מופיע פעם אחת\)/);
      assert.match(answer,/ירושלים/);
      assert.doesNotMatch(answer,/משותף בשתי קבוצות|עיר חסויה/);
    });
    await t.test('phone and city permissions still apply to broader group scope',async()=>{
      const answer=await executeGuideDataPlan(db,me,plan({fields:['name','phone','city','groups']}));
      assert.doesNotMatch(answer,/0501111111/);
      assert.doesNotMatch(answer,/0502222222|עיר חסויה|עיר ישנה של קטין/);
      assert.match(answer,/לא זמין להצגה/);
    });
    await t.test('adding city to the saved-contact list preserves ownership and requested fields',async()=>{
      const answer=await executeGuideDataPlan(db,me,plan({kind:'contacts',group_scope:'named',contact_filter:'all',
        fields:['name','phone','city'],format:'list'}));
      assert.match(answer,/אנשי הקשר השמורים שלך \(1\)/);
      assert.match(answer,/שם זהה/);
      assert.match(answer,/עיר מגורים: ירושלים/);
      assert.match(answer,/טלפון: לא זמין להצגה/);
      assert.doesNotMatch(answer,/משותף בשתי קבוצות|עיר חסויה|עיר ישנה של קטין/);
    });
    await t.test('specific group comparison uses same saved-contact filter',async()=>{
      const answer=await executeGuideDataPlan(db,me,plan({group_scope:'named',group_query:'קבוצה ב'}));
      assert.match(answer,/משותף בשתי קבוצות/);
      assert.doesNotMatch(answer,/שם זהה|המבקש|קבוצה א/);
    });
    await t.test('teen and unknown-age requesters cannot use all-groups route',async()=>{
      assert.match(await executeGuideDataPlan(db,teen,plan()),/חשבון נוער/);
      await db.query('UPDATE users SET birth_date=NULL WHERE id=$1',[teen]);
      assert.match(await executeGuideDataPlan(db,teen,plan()),/חשבון נוער/);
    });
    await t.test('no membership gives zero results without revealing another group',async()=>{
      const answer=await executeGuideDataPlan(db,pending,plan());
      assert.match(answer,/לא נמצאו/);
      assert.doesNotMatch(answer,/משותף בשתי קבוצות|קבוצה א|קבוצה ב/);
    });
    await t.test('revoking requester membership before the read removes both groups immediately',async()=>{
      const pool={query:async(sql,values)=>{
        const result=await db.query(sql,values);
        if(sql.includes('AS is_teen'))await db.query("UPDATE group_members SET status='removed' WHERE user_id=$1",[me]);
        return result;
      }};
      assert.match(await executeGuideDataPlan(pool,me,plan({format:'count'})),/: 0\./);
    });
  } finally {await db.query('ROLLBACK');await db.end();}
});
