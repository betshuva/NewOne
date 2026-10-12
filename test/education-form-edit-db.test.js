const test = require('node:test');
const assert = require('node:assert/strict');
const { registerEducationFormEditing } = require('../server/education-form-edit');
test('PostgreSQL archives answered surveys atomically in isolated temporary tables',
  { skip: process.env.EDUCATION_TEST_DB !== '1' }, async () => {
  require('dotenv').config({quiet: true});
  const {Client} = require('pg');
  const client = new Client({connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? {rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false'} : false});
  await client.connect();
  try {
    await client.query('SET search_path TO pg_temp, public');
    await client.query(`CREATE TEMP TABLE groups(id uuid,name text,send_permission text DEFAULT 'all');
      CREATE TEMP TABLE group_members(group_id uuid,user_id uuid,role text,status text);
      CREATE TEMP TABLE education_forms(id uuid,group_id uuid,created_by uuid,form_type text,title text,description text,
        file_url text,file_name text,questions jsonb,anonymous boolean,due_at timestamptz,updated_at timestamptz);
      CREATE TEMP TABLE education_form_responses(form_id uuid,user_id uuid,answers jsonb);
      CREATE TEMP TABLE education_form_recipients(form_id uuid,user_id uuid);
      CREATE TEMP TABLE education_response_change_requests(form_id uuid,user_id uuid);
      CREATE TEMP TABLE education_form_revisions(id uuid DEFAULT gen_random_uuid(),form_id uuid,
        edited_by uuid,snapshot jsonb,responses jsonb,created_at timestamptz DEFAULT now());`);
    const [group, admin, formId, recipient] = Array.from({length:4}, () => require('crypto').randomUUID());
    await client.query('INSERT INTO groups(id,name) VALUES($1,$2)', [group,'בדיקה']);
    await client.query("INSERT INTO group_members VALUES($1,$2,'admin','member')", [group,admin]);
    await client.query(`INSERT INTO education_forms(id,group_id,form_type,title,questions,anonymous,updated_at)
      VALUES($1,$2,'survey','מקורי',$3,true,now())`, [formId,group,JSON.stringify([{text:'מתי?',options:['בוקר','ערב']}])]);
    await client.query('INSERT INTO education_form_responses VALUES($1,$2,$3)', [formId,recipient,'{"0":"בוקר"}']);
    await client.query('INSERT INTO education_form_recipients VALUES($1,$2)', [formId,recipient]);
    let handler;
    registerEducationFormEditing({get(){},put(path,auth,fn){handler=fn;}}, {auth(){},
      getPool: async () => ({connect: async () => ({query: client.query.bind(client),release(){}})}),
      io: {to: () => ({emit(){}})},sendPush(){}});
    const old = (await client.query('SELECT * FROM education_forms')).rows[0];
    const res={code:200,status(c){this.code=c;return this;},json(b){this.body=b;}};
    await handler({params:{id:formId},user:{id:admin},body:{title:'מעודכן',anonymous:true,
      questions:[...old.questions,{text:'איפה?',options:['כאן','שם']}],expectedUpdatedAt:old.updated_at}},res);
    assert.equal(res.code,200);
    assert.equal((await client.query('SELECT * FROM education_form_responses')).rowCount,0);
    const archived=(await client.query('SELECT * FROM education_form_revisions')).rows[0];
    assert.equal(archived.snapshot.title,'מקורי');
    assert.equal(archived.responses[0].answers[0],'בוקר');
    assert.equal((await client.query('SELECT questions FROM education_forms')).rows[0].questions.length,2);
    // Every mutated object is temporary and disappears when this connection closes.
  } finally {await client.end();}
});
