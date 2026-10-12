const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const source = fs.readFileSync(require('node:path').join(__dirname, '../server/index.js'), 'utf8');
const start = source.indexOf("app.get('/api/groups/:id/education-forms'");
const end = source.indexOf('// ── Groups: invite a registered user', start);

test('group content and forms wait for invitation acceptance before becoming accessible',
  { skip: process.env.EDUCATION_TEST_DB !== '1' }, async () => {
  require('dotenv').config({quiet:true});
  const {Client}=require('pg');
  const db=new Client({connectionString:process.env.DATABASE_URL,
    ssl:process.env.DB_SSL==='true'?{rejectUnauthorized:process.env.DB_REJECT_UNAUTHORIZED!=='false'}:false});
  await db.connect();
  try {
    await db.query('SET search_path TO pg_temp, public');
    await db.query(`CREATE TEMP TABLE groups(id uuid,name text,send_permission text DEFAULT 'all');
      CREATE TEMP TABLE users(id uuid,name text,content_filter jsonb);
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,role text,status text,share_phone boolean,pending_since timestamptz DEFAULT now(),filter_override jsonb,joined_at timestamptz DEFAULT now());
      CREATE TEMP TABLE education_forms(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),group_id uuid,
        created_by uuid,form_type text,title text,description text,file_url text,file_name text,
        questions jsonb,anonymous boolean,due_at timestamptz,status text DEFAULT 'open',
        created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now());
      CREATE TEMP TABLE education_form_recipients(form_id uuid,user_id uuid,notified_at timestamptz,
        PRIMARY KEY(form_id,user_id));
      CREATE TEMP TABLE education_form_responses(form_id uuid,user_id uuid,response_status text,answers jsonb,
        signer_name text,signature_data jsonb,document_version text,submitted_at timestamptz DEFAULT now(),
        PRIMARY KEY(form_id,user_id));
      CREATE TEMP TABLE education_response_change_requests(form_id uuid,user_id uuid,status text);
      CREATE TEMP TABLE education_form_reminders(form_id uuid,sent_by uuid,recipient_id uuid,sent_at timestamptz DEFAULT now());
      CREATE TEMP TABLE education_form_revisions(id uuid,form_id uuid,snapshot jsonb,responses jsonb,created_at timestamptz);
      CREATE TEMP TABLE stored_files(public_url text,moderation_status text,content_purged_at timestamptz,
        context_type text,context_id uuid,user_id uuid,moderation_details jsonb,client_upload_id text);
      CREATE TEMP TABLE messages(id uuid DEFAULT gen_random_uuid(),sender_id uuid,group_id uuid,body text,
        type text,education_form_id uuid,created_at timestamptz DEFAULT now(),
        file_url text,file_name text,reply_to_id uuid,deleted_for_everyone boolean DEFAULT false,delivery_summary jsonb);
      CREATE TEMP TABLE message_status(message_id uuid,user_id uuid,status text);
      CREATE TEMP TABLE message_user_deletions(message_id uuid,user_id uuid);`);
    const [group,admin,pending,other,active,outsider]=Array.from({length:6},()=>crypto.randomUUID());
    await db.query('INSERT INTO groups(id,name) VALUES($1,$2)',[group,'קבוצת בדיקה']);
    for(const [id,name,role,status] of [[admin,'מנהל','admin','member'],[pending,'מוזמן','member','pending'],
      [other,'מוזמן נוסף','member','pending'],[active,'חבר פעיל','member','member'],[outsider,'חיצוני',null,null]]) {
      await db.query('INSERT INTO users(id,name) VALUES($1,$2)',[id,name]);
      if(role)await db.query('INSERT INTO group_members(group_id,user_id,role,status) VALUES($1,$2,$3,$4)',[group,id,role,status]);
    }
    const file='/betshuva-app/uploads/test-form.pdf';
    await db.query("INSERT INTO stored_files(public_url,moderation_status,content_purged_at,context_type,context_id,user_id) VALUES($1,'approved',NULL,'group',$2,$3)",[file,group,admin]);
    const handlers=new Map(),pushes=[];
    const pool={query:db.query.bind(db),connect:async()=>({query:db.query.bind(db),release(){}})};
    vm.runInNewContext(source.slice(start,end),{app:{get(p,a,h){handlers.set('GET '+p,h);},
      post(p,...middleware){handlers.set('POST '+p,middleware.at(-1));},put(p,a,h){handlers.set('PUT '+p,h);}},
      ...require('../server/education-survey-questions'),
      denyTeenEducation: require('../server/education-form-policy').denyTeenEducation,
      educationFormPolicy: { canSend: async () => true, validateContent: async () => {} },
      auth(){},messageRateLimit(){},getPool:async()=>pool,crypto,console,logActivity(){},sendPush:(...p)=>pushes.push(p),
      io:{to:()=>({emit(){}})}});
    async function call(method,path,user,params,body={}) {
      const res={code:200,status(c){this.code=c;return this;},json(b){this.body=b;return this;}};
      await handlers.get(method+' '+path)({params,user:{id:user,name:'בדיקה'},body,app:{get:()=>({to:()=>({emit(){}})})}},res);
      return res;
    }
    const joinStart=source.indexOf("app.post('/api/groups/:id/join'");
    const joinEnd=source.indexOf('// ── Groups: decline pending invite',joinStart);
    vm.runInNewContext(source.slice(joinStart,joinEnd),{app:{post(p,a,h){handlers.set('POST '+p,h);}},
      auth(){},getPool:async()=>pool,resolveScopedContentFilter:()=>({}),
      filterPinQuery:async (pool,req,sql,args)=>pool.query(sql,args),
      contentAllowedByFilter:()=>true,retainVisibleReceivedMessages:async()=>{},
      personalizeReceivedMessages:async(pool,user,messages)=>messages,console});
    await db.query(`INSERT INTO messages(sender_id,group_id,type,body,created_at)
      VALUES($1,$2,'text','לפני ההזמנה',now()-interval '1 day')`,[admin,group]);
    for(const type of ['text','image','video','audio','document'])
      await db.query('INSERT INTO messages(sender_id,group_id,type,body,file_url,file_name) VALUES($1,$2,$3,$4,$5,$6)',
        [admin,group,type,'תוכן '+type,type==='text'?null:file,type==='text'?null:'קובץ']);
    await db.query("UPDATE group_members SET joined_at=now()-interval '2 days' WHERE user_id=$1",[pending]);
    const defaultForm=await call('POST','/api/groups/:id/education-forms',admin,{id:group},
      {formType:'approval',title:'לכל הקבוצה'});
    assert.equal(defaultForm.code,201);
    const queued=(await db.query('SELECT user_id FROM education_form_recipients WHERE form_id=$1',[defaultForm.body.id])).rows.map(r=>r.user_id);
    assert(queued.includes(pending) && queued.includes(other) && queued.includes(active) && queued.includes(admin));
    assert.equal(defaultForm.body.isRecipient,true);
    assert(!pushes.some(p=>p[0]===admin),'The sender is enrolled without a self-push for publication');
    assert(!pushes.some(p=>p[0]===pending || p[0]===other));
    assert(pushes.some(p=>p[0]===active));
    const forms=[];
    for(const type of ['survey','approval','signature']) {
      await db.query("UPDATE group_members SET status='pending' WHERE user_id=$1",[pending]);
      const created=await call('POST','/api/groups/:id/education-forms',admin,{id:group},{formType:type,
        title:'טופס '+type,questions:[{text:'מתי?',options:['בוקר','ערב']}],recipientIds:[pending],
        ...(type==='signature'?{fileUrl:file,fileName:'מסמך.pdf'}:{})});
      assert.equal(created.code,201,JSON.stringify(created.body));forms.push(created.body);
      assert.equal(created.body.isRecipient,false,'An explicit audience may exclude the sender');
      assert.equal((await call('GET','/api/education-forms/:id',pending,{id:created.body.id})).code,404);
      assert.equal((await call('GET','/api/groups/:id/education-forms',pending,{id:group})).code,403);
      const answer={status:type==='survey'?'completed':'approved',answers:{0:'בוקר'},signerName:'מוזמן',
        signatureData:[{x:1,y:1},{x:2,y:2}],expectedUpdatedAt:created.body.updated_at};
      assert.equal((await call('POST','/api/education-forms/:id/respond',pending,{id:created.body.id},answer)).code,404);
      assert.equal(pushes.some(p=>p[0]===pending),false,'No content notifications before acceptance');
      const joined=await call('POST','/api/groups/:id/join',pending,{id:group},{share_phone:false});
      assert.equal(joined.code,200,JSON.stringify(joined.body));
      const membership=(await db.query('SELECT joined_at,pending_since FROM group_members WHERE user_id=$1',[pending])).rows[0];
      assert.equal(membership.joined_at.getTime(),membership.pending_since.getTime());
      for(const kind of ['text','image','video','audio','document'])
        assert(joined.body.missedMessages.some(m=>m.type===kind));
      const missedForm=joined.body.missedMessages.find(m=>m.education_form_id===created.body.id);
      assert(missedForm);
      assert.equal(missedForm.education_form_title,created.body.title);
      assert.equal(missedForm.education_form_type,type);
      assert.equal(missedForm.education_form_creator_id,admin);
      assert.equal(missedForm.education_form_status,'open');
      assert.equal(missedForm.education_is_recipient,true);
      assert.equal(new Date(missedForm.education_form_created_at).getTime(),new Date(created.body.created_at).getTime());
      assert(!joined.body.missedMessages.some(m=>m.body==='לפני ההזמנה'));
      const details=await call('GET','/api/education-forms/:id',pending,{id:created.body.id});
      assert.equal(details.code,200);assert.equal(details.body.form.my_role,'member');
      assert.equal(details.body.form.isRecipient,true);
      assert.equal(details.body.participants,null);assert.equal(details.body.results,null);
      assert.equal((await call('POST','/api/education-forms/:id/respond',pending,{id:created.body.id},answer)).code,200);
    }
    const survey=forms[0];
    const list=await call('GET','/api/groups/:id/education-forms',pending,{id:group});
    assert.equal(list.code,200);assert.equal(list.body.isAdmin,false);assert.equal(list.body.forms.length,4);
    assert.equal((await call('POST','/api/groups/:id/education-forms',pending,{id:group},{formType:'approval',title:'חבר פעיל יכול ליצור'})).code,201);
    assert.equal((await call('PUT','/api/education-forms/:id/status',pending,{id:survey.id},{status:'closed'})).code,403);
    assert.equal((await call('POST','/api/education-forms/:id/assign-new-members',pending,{id:survey.id},{recipientIds:[other]})).code,403);
    const assigned=await call('POST','/api/education-forms/:id/assign-new-members',admin,{id:survey.id},{recipientIds:[other]});
    assert.equal(assigned.code,200);assert.equal(assigned.body.sent,1);
    assert.equal((await call('GET','/api/education-forms/:id',other,{id:survey.id})).code,404);
    assert.equal((await call('POST','/api/education-forms/:id/remind',admin,{id:survey.id},{userIds:[other]})).body.sent,0);
    assert(!pushes.some(p=>p[0]===other));
    assert.equal((await call('POST','/api/groups/:id/join',other,{id:group})).code,200);
    assert.equal((await call('GET','/api/education-forms/:id',other,{id:survey.id})).code,200);
    assert.equal((await call('POST','/api/education-forms/:id/remind',admin,{id:survey.id},{userIds:[other]})).body.sent,1);
    // Execute the actual history SELECT to ensure the same form message carries
    // each viewer's recipient state and the current form title after an edit.
    const historyStart=source.indexOf('    const historySql = `',source.indexOf("app.get('/api/groups/:id/messages'"));
    const historyEnd=source.indexOf('    const historyQuery = ',historyStart);
    const historySql=vm.runInNewContext(source.slice(historyStart,historyEnd)+'historySql',
      {before:null,messageAfterConversationClear:()=> 'TRUE'});
    await db.query('UPDATE education_forms SET title=$2 WHERE id=$1',[survey.id,'סקר מעודכן בשם ברור']);
    for(const [viewer,isRecipient] of [[admin,false],[pending,true],[other,true]]) {
      const history=(await db.query(historySql,[group,viewer])).rows;
      const announcement=history.find(message=>message.education_form_id===survey.id);
      assert(announcement);
      assert.equal(announcement.education_form_title,'סקר מעודכן בשם ברור');
      assert.equal(announcement.education_form_type,'survey');
      assert.equal(announcement.education_form_creator_id,admin);
      assert.equal(announcement.education_form_status,'open');
      assert.equal(announcement.education_is_recipient,isRecipient,
        'Recipient state is computed for the history viewer rather than broadcast to everyone');
      assert.equal(new Date(announcement.education_form_created_at).getTime(),new Date(survey.created_at).getTime());
    }
    await db.query("UPDATE group_members SET role='admin' WHERE user_id=$1",[active]);
    assert.equal((await call('POST','/api/education-forms/:id/republish',active,{id:survey.id})).code,200);
    const creatorHistory=(await db.query(historySql,[group,admin])).rows;
    const adminRepublished=creatorHistory.find(message=>message.education_form_id===survey.id && message.sender_id===active);
    assert(adminRepublished);
    assert.equal(adminRepublished.education_form_creator_id,admin,
      'The original creator retains management when another admin republishes an announcement');
    assert.equal(adminRepublished.education_is_recipient,false,'Management does not force creator participation');
    await db.query("UPDATE group_members SET status='removed' WHERE user_id=$1",[other]);
    assert.equal((await call('GET','/api/education-forms/:id',other,{id:survey.id})).code,404);
    assert.equal((await call('GET','/api/groups/:id/education-forms',outsider,{id:group})).code,403);
  } finally {await db.end();}
});
