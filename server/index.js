require('dotenv').config();
const express = require('express');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { getPool, sql } = require('./db');

const app = express();
app.use(cors());
app.use(express.json());
app.use(express.static(require('path').join(__dirname, '..')));

const JWT_SECRET = process.env.JWT_SECRET || 'change-this-secret';

function auth(req, res, next) {
  const token = req.headers.authorization?.split(' ')[1];
  if (!token) return res.status(401).json({ error: 'לא מחובר' });
  try {
    req.user = jwt.verify(token, JWT_SECRET);
    next();
  } catch {
    res.status(401).json({ error: 'טוקן לא תקין' });
  }
}

// ── Register ─────────────────────────────────────────────────────
app.post('/api/register', async (req, res) => {
  const { name, email, password } = req.body;
  if (!name || !email || !password) return res.status(400).json({ error: 'חסרים שדות' });
  try {
    const pool = await getPool();
    const exists = await pool.request()
      .input('email', sql.NVarChar, email)
      .query('SELECT id FROM users WHERE email = @email');
    if (exists.recordset.length) return res.status(400).json({ error: 'האימייל כבר רשום' });

    const hash = await bcrypt.hash(password, 10);
    const result = await pool.request()
      .input('name', sql.NVarChar, name)
      .input('email', sql.NVarChar, email)
      .input('hash', sql.NVarChar, hash)
      .query(`INSERT INTO users (name, email, password_hash)
              OUTPUT INSERTED.id, INSERTED.name, INSERTED.email, INSERTED.wins, INSERTED.games_played
              VALUES (@name, @email, @hash)`);
    const user = result.recordset[0];
    const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
    res.json({ token, user });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Login ────────────────────────────────────────────────────────
app.post('/api/login', async (req, res) => {
  const { email, password } = req.body;
  try {
    const pool = await getPool();
    const result = await pool.request()
      .input('email', sql.NVarChar, email)
      .query('SELECT * FROM users WHERE email = @email');
    const user = result.recordset[0];
    if (!user || !(await bcrypt.compare(password, user.password_hash)))
      return res.status(401).json({ error: 'אימייל או סיסמה שגויים' });

    const token = jwt.sign({ id: user.id, name: user.name, email: user.email }, JWT_SECRET);
    const { password_hash, ...safeUser } = user;
    res.json({ token, user: safeUser });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Get all users (for opponent selection) ───────────────────────
app.get('/api/users', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.request()
      .query('SELECT id, name, email, wins, games_played FROM users ORDER BY wins DESC');
    res.json(result.recordset);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Save game ────────────────────────────────────────────────────
app.post('/api/games', auth, async (req, res) => {
  const { player1_id, player2_id, winner_id, result, board } = req.body;
  try {
    const pool = await getPool();
    await pool.request()
      .input('p1', sql.UniqueIdentifier, player1_id)
      .input('p2', sql.UniqueIdentifier, player2_id)
      .input('winner', sql.UniqueIdentifier, winner_id || null)
      .input('result', sql.NVarChar, result)
      .input('board', sql.NVarChar, board.join(','))
      .query(`INSERT INTO games (player1_id, player2_id, winner_id, result, board)
              VALUES (@p1, @p2, @winner, @result, @board)`);

    if (result === 'win' && winner_id) {
      await pool.request()
        .input('id', sql.UniqueIdentifier, winner_id)
        .query('UPDATE users SET wins = wins + 1, games_played = games_played + 1 WHERE id = @id');
      const loserId = winner_id === player1_id ? player2_id : player1_id;
      await pool.request()
        .input('id', sql.UniqueIdentifier, loserId)
        .query('UPDATE users SET games_played = games_played + 1 WHERE id = @id');
    } else if (result === 'tie') {
      await pool.request()
        .input('p1', sql.UniqueIdentifier, player1_id)
        .input('p2', sql.UniqueIdentifier, player2_id)
        .query('UPDATE users SET games_played = games_played + 1 WHERE id IN (@p1, @p2)');
    }

    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Leaderboard ──────────────────────────────────────────────────
app.get('/api/leaderboard', auth, async (req, res) => {
  try {
    const pool = await getPool();
    const result = await pool.request()
      .query('SELECT name, email, wins, games_played FROM users ORDER BY wins DESC');
    res.json(result.recordset);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`Server running on port ${PORT}`));
