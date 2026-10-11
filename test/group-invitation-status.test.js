const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require('node:path').join(__dirname, '../server/index.js'), 'utf8');
const start = source.indexOf("app.get('/api/groups/:id',");
const end = source.indexOf("app.put('/api/groups/:id/phone-sharing'", start);
function harness(member) {
  let handler;
  const queries = [];
  const pool = { async query(sql) {
    queries.push(sql);
    if (sql.includes('SELECT role,share_phone')) return { rows: member ? [member] : [] };
    if (sql.includes('SELECT * FROM groups')) return { rows: [{id:'group'}] };
    if (sql.includes("gm.status='member'")) return { rows: [{id:'joined',name:'Joined'}] };
    if (sql.includes("status='pending'")) return { rows: [{user_id:'invited',name:'Invited'}] };
    throw Error(sql);
  }};
  vm.runInNewContext(source.slice(start, end), {
    app: {get(path, auth, callback) { handler = callback; }}, auth() {},
    getPool: async () => pool,
    projectProfileImages: async (db, viewer, rows) => rows,
    projectContactPhones: async (db, viewer, rows) => rows,
  });
  const response = {code:200, status(code) { this.code=code; return this; },
    set() {return this;}, json(body) {this.body=body; return this;}};
  return {queries,response,run:()=>handler({params:{id:'group'},user:{id:'viewer'}}, response)};
}
test('admin can see pending invitations without treating them as active members', async () => {
  const h=harness({role:'admin',share_phone:false}); await h.run();
  assert.equal(h.response.code,200);
  assert.deepEqual(Array.from(h.response.body.pending_invite_ids),['invited']);
  assert.deepEqual(Array.from(h.response.body.members, m=>m.id),['joined']);
});
test('ordinary members do not receive pending invitation identities', async () => {
  const h=harness({role:'member'}); await h.run();
  assert.equal(h.response.code,200);
  assert.equal(h.response.body.pending_invite_ids,undefined);
  assert.equal(h.response.body.pending_invitees,undefined);
  assert.equal(h.queries.some(q=>q.includes("status='pending'")),false);
});
test('inactive users cannot view membership or invitations', async () => {
  const h=harness(null); await h.run();
  assert.equal(h.response.code,403); assert.equal(h.queries.length,1);
});
