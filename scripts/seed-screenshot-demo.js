require('dotenv').config();
const { getPool } = require('../server/db');

const ownerEmail = process.argv[2];
if (!ownerEmail) {
  console.error('Usage: node scripts/seed-screenshot-demo.js <owner-email>');
  process.exit(1);
}

const people = [
  {
    key: 'rabbi_akiva',
    name: 'רבי עקיבא — לימוד יומי',
    email: 'demo.rabbi-akiva@betshuva.local',
    gender: 'male',
    image: '/betshuva-app/uploads/demo-historical/rabbi-akiva.webp',
    messages: [
      'הלימוד היומי החדש מחכה לך.',
      'כל התחלה קטנה יכולה להוביל לדרך גדולה.',
    ],
  },
  {
    key: 'rambam',
    name: 'הרמב״ם — חכמה ובריאות',
    email: 'demo.rambam@betshuva.local',
    gender: 'male',
    image: '/betshuva-app/uploads/demo-historical/rambam.webp',
    messages: [
      'תזכורת טובה: לשמור היום על איזון ומנוחה.',
      'קטע חדש בנושאי חכמה ובריאות נוסף ללימוד.',
    ],
  },
  {
    key: 'beruriah',
    name: 'ברוריה — לימוד יומי',
    email: 'demo.beruriah@betshuva.local',
    gender: 'female',
    image: '/betshuva-app/uploads/demo-historical/beruriah.webp',
    messages: [
      'שאלת הלימוד היומית מוכנה.',
      'תודה על השיתוף המחכים בקבוצה.',
    ],
  },
  {
    key: 'sarah_schenirer',
    name: 'שרה שנירר — חינוך',
    email: 'demo.sarah-schenirer@betshuva.local',
    gender: 'female',
    image: '/betshuva-app/uploads/demo-historical/sarah-schenirer.webp',
    messages: [
      'מחשבה חינוכית חדשה נוספה הבוקר.',
      'כל הכבוד על היוזמה למען הקהילה!',
    ],
  },
  {
    key: 'chofetz_chaim',
    name: 'החפץ חיים — לימוד יומי',
    email: 'demo.chofetz-chaim@betshuva.local',
    gender: 'male',
    image: '/betshuva-app/uploads/demo-historical/chofetz-chaim.webp',
    messages: [
      'הלימוד היומי בנושא שמירת הלשון מוכן.',
      'מילה טובה יכולה להאיר יום שלם.',
    ],
  },
  {
    key: 'eliyahu',
    name: 'אליהו בן־אורי',
    email: 'demo.eliyahu@betshuva.local',
    gender: 'male',
    image: '/betshuva-app/uploads/demo-historical/first-temple-man.webp',
    messages: [
      'בוקר טוב ומבורך!',
      'הדברים שכתבת נתנו הרבה כוח.',
      '🙏 תודה רבה על העזרה והעידוד!',
    ],
  },
  {
    key: 'avigail',
    name: 'אביגיל בת־עמינדב',
    email: 'demo.avigail@betshuva.local',
    gender: 'female',
    image: '/betshuva-app/uploads/demo-historical/first-temple-woman.webp',
    messages: [
      'תודה על השיתוף החשוב.',
      'איזה יופי, הבשורה ממש משמחת!',
    ],
  },
  {
    key: 'yonatan',
    name: 'יונתן הלוי',
    email: 'demo.yonatan@betshuva.local',
    gender: 'male',
    image: '/betshuva-app/uploads/demo-historical/second-temple-man.webp',
    messages: [
      'שבוע טוב ובשורות טובות.',
      'יישר כוח על היוזמה.',
      'כולם שמחו מאוד לשמוע.',
      'נשמח לעזור בכל מה שצריך.',
      'חזק וברוך, הדברים נתנו הרבה כוח.',
    ],
  },
  {
    key: 'miriam',
    name: 'מרים בת־יהודה',
    email: 'demo.miriam@betshuva.local',
    gender: 'female',
    image: '/betshuva-app/uploads/demo-historical/second-temple-woman.webp',
    messages: ['שיהיה יום מבורך ומלא בשורות טובות 🌿'],
    read: true,
  },
];

const groups = [
  {
    marker: '[SCREENSHOT_DEMO_MEN]',
    name: 'לומדים יחד — גברים',
    image: '/betshuva-app/uploads/demo-historical/temple-men-group.webp',
    members: [
      'chofetz_chaim',
      'rabbi_akiva',
      'rambam',
      'eliyahu',
      'yonatan',
    ],
    messages: [
      'ברוכים הבאים לקבוצה!',
      'השיעור הערב בשעה שמונה.',
      'תודה לכל מי שעזר בארגון.',
      'נשלח כאן את הסיכום בהמשך.',
      'יישר כוח לכולם.',
      'נפגשים במקום הקבוע.',
      'מחכים לראות את כולכם.',
      'בשורות טובות והמשך יום מבורך!',
    ],
  },
  {
    marker: '[SCREENSHOT_DEMO_WOMEN]',
    name: 'קהילת חסד — נשים',
    image: '/betshuva-app/uploads/demo-historical/temple-women-group.webp',
    members: ['beruriah', 'sarah_schenirer', 'avigail', 'miriam'],
    messages: [
      'ברוכות הבאות לקהילה!',
      'הפעילות הקרובה מוכנה.',
      'יישר כוח על כל העזרה.',
      'תודה לכל מי שהתנדבה ❤️',
    ],
  },
];

async function main() {
  const pool = await getPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const ownerResult = await client.query(
      'SELECT id,name FROM users WHERE lower(email)=lower($1) LIMIT 1',
      [ownerEmail],
    );
    if (!ownerResult.rows.length) throw new Error('חשבון היעד לא נמצא');
    const owner = ownerResult.rows[0];
    const ids = {};

    for (const person of people) {
      const result = await client.query(
        `INSERT INTO users
           (name,email,email_verified,gender,birth_date,profile_pic_url,city,country)
         VALUES($1,$2,TRUE,$3,'1990-01-01',$4,'ירושלים','ישראל')
         ON CONFLICT(email) DO UPDATE SET
           name=EXCLUDED.name,gender=EXCLUDED.gender,birth_date=EXCLUDED.birth_date,
           profile_pic_url=EXCLUDED.profile_pic_url,city=EXCLUDED.city,country=EXCLUDED.country
         RETURNING id`,
        [person.name, person.email, person.gender, `${person.image}?v=painted1`],
      );
      ids[person.key] = result.rows[0].id;
      await client.query(
        `INSERT INTO user_contacts(owner_id,contact_id) VALUES($1,$2),($2,$1)
         ON CONFLICT DO NOTHING`,
        [owner.id, result.rows[0].id],
      );

      await client.query(
        `UPDATE messages
         SET body=substring(body from char_length('[צילום] ')+1),
             file_name='SCREENSHOT_DEMO'
         WHERE sender_id=$1 AND recipient_id=$2 AND body LIKE '[צילום]%'`,
        [result.rows[0].id, owner.id],
      );

      const existing = await client.query(
        `SELECT 1 FROM messages WHERE sender_id=$1 AND recipient_id=$2
         AND file_name='SCREENSHOT_DEMO' LIMIT 1`,
        [result.rows[0].id, owner.id],
      );
      if (!existing.rows.length) {
        for (let i = 0; i < person.messages.length; i++) {
          const message = await client.query(
            `INSERT INTO messages(sender_id,recipient_id,type,body,created_at)
             VALUES($1,$2,'text',$3,now()-($4::int || ' minutes')::interval)
             RETURNING id`,
            [result.rows[0].id, owner.id, person.messages[i],
              person.messages.length - i + 5],
          );
          await client.query(
            `UPDATE messages SET file_name='SCREENSHOT_DEMO' WHERE id=$1`,
            [message.rows[0].id],
          );
          if (person.read) {
            await client.query(
              `INSERT INTO message_status(message_id,user_id,status)
               VALUES($1,$2,'read') ON CONFLICT DO NOTHING`,
              [message.rows[0].id, owner.id],
            );
          }
        }
      }
    }

    for (const group of groups) {
      let groupResult = await client.query(
        'SELECT id FROM groups WHERE creator_id=$1 AND description=$2 LIMIT 1',
        [owner.id, group.marker],
      );
      if (!groupResult.rows.length) {
        groupResult = await client.query(
          `INSERT INTO groups(name,description,creator_id,profile_pic_url)
           VALUES($1,$2,$3,$4) RETURNING id`,
          [group.name, group.marker, owner.id, `${group.image}?v=painted1`],
        );
      } else {
        await client.query(
          'UPDATE groups SET name=$1,profile_pic_url=$2 WHERE id=$3',
          [group.name, `${group.image}?v=painted1`, groupResult.rows[0].id],
        );
      }
      const groupId = groupResult.rows[0].id;
      await client.query(
        `INSERT INTO group_members(group_id,user_id,role,status,joined_at)
         VALUES($1,$2,'admin','member',now()-interval '30 days')
         ON CONFLICT(group_id,user_id) DO UPDATE SET role='admin',status='member'`,
        [groupId, owner.id],
      );
      for (const key of group.members) {
        await client.query(
          `INSERT INTO group_members(group_id,user_id,role,status,joined_at)
           VALUES($1,$2,'member','member',now()-interval '30 days')
           ON CONFLICT(group_id,user_id) DO UPDATE SET status='member'`,
          [groupId, ids[key]],
        );
      }
      await client.query(
        `UPDATE messages
         SET body=substring(body from char_length('[צילום] ')+1),
             file_name='SCREENSHOT_DEMO'
         WHERE group_id=$1 AND body LIKE '[צילום]%'`,
        [groupId],
      );
      const existing = await client.query(
        `SELECT 1 FROM messages WHERE group_id=$1
         AND file_name='SCREENSHOT_DEMO' LIMIT 1`,
        [groupId],
      );
      if (!existing.rows.length) {
        for (let i = 0; i < group.messages.length; i++) {
          const sender = ids[group.members[i % group.members.length]];
          await client.query(
            `INSERT INTO messages(sender_id,group_id,type,body,file_name,created_at)
             VALUES($1,$2,'text',$3,'SCREENSHOT_DEMO',
                    now()-($4::int || ' minutes')::interval)`,
            [sender, groupId, group.messages[i],
              group.messages.length - i + 15],
          );
        }
      }
    }

    await client.query('COMMIT');
    console.log(JSON.stringify({
      ok: true,
      owner: owner.name,
      users: people.length,
      groups: groups.length,
      unreadDirectMessages: people.filter((p) => !p.read)
        .reduce((sum, p) => sum + p.messages.length, 0),
      unreadGroupMessages: groups.reduce((sum, g) => sum + g.messages.length, 0),
    }));
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
    await pool.end();
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
