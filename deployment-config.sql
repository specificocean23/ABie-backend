# Railway PostgreSQL Configuration for AboutBlank
# Connection Pooling + Rate Limiting + Security

# ==============================================================================
# POSTGRESQL DATABASE SCHEMA
# ==============================================================================

-- Create main tables with proper indexes
CREATE TABLE IF NOT EXISTS users (
    auth_key_hash TEXT PRIMARY KEY,
    created_at TIMESTAMP DEFAULT NOW(),
    last_active TIMESTAMP DEFAULT NOW(),
    security_level TEXT DEFAULT 'standard'
);

CREATE TABLE IF NOT EXISTS progress (
    auth_key_hash TEXT PRIMARY KEY REFERENCES users(auth_key_hash) ON DELETE CASCADE,
    start_date TIMESTAMP,
    goal_days INTEGER DEFAULT 90,
    goal_description TEXT,
    check_ins JSONB DEFAULT '[]'::jsonb,
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS cravings (
    id SERIAL PRIMARY KEY,
    auth_key_hash TEXT REFERENCES users(auth_key_hash) ON DELETE CASCADE,
    timestamp TIMESTAMP DEFAULT NOW(),
    intensity INTEGER,
    triggers JSONB DEFAULT '[]'::jsonb,
    notes TEXT,
    overcome BOOLEAN,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS challenge_progress (
    auth_key_hash TEXT PRIMARY KEY REFERENCES users(auth_key_hash) ON DELETE CASCADE,
    xp_points INTEGER DEFAULT 0,
    current_challenge_index INTEGER DEFAULT 0,
    last_skip_time TIMESTAMP,
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS anonymous_messages (
    id SERIAL PRIMARY KEY,
    message TEXT NOT NULL,
    days_clean INTEGER DEFAULT 0,
    emoji TEXT DEFAULT '💪',
    created_at TIMESTAMP DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_cravings_auth ON cravings(auth_key_hash);
CREATE INDEX IF NOT EXISTS idx_cravings_timestamp ON cravings(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_users_last_active ON users(last_active DESC);

-- Create function to update last_active
CREATE OR REPLACE FUNCTION update_last_active()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE users SET last_active = NOW() WHERE auth_key_hash = NEW.auth_key_hash;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create triggers for last_active updates
CREATE TRIGGER update_last_active_progress
AFTER INSERT OR UPDATE ON progress
FOR EACH ROW EXECUTE FUNCTION update_last_active();

CREATE TRIGGER update_last_active_cravings
AFTER INSERT ON cravings
FOR EACH ROW EXECUTE FUNCTION update_last_active();

-- ==============================================================================
# NODE.JS API SERVER WITH RATE LIMITING
# ==============================================================================
# Save this as railway/server.js

const express = require('express');
const { Pool } = require('pg');
const rateLimit = require('express-rate-limit');
const helmet = require('helmet');
const cors = require('cors');
const compression = require('compression');

const app = express();
const PORT = process.env.PORT || 8080;

// ==============================================================================
// PGBOUNCER CONNECTION POOLING (Railway automatically provides this)
// ==============================================================================
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: { rejectUnauthorized: false },
  max: 20, // Maximum pool size
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 10000,
});

// ==============================================================================
// SECURITY MIDDLEWARE
// ==============================================================================
app.use(helmet()); // Security headers
app.use(cors({
  origin: ['https://aboutblank.ie', 'http://localhost:3003'],
  credentials: true,
}));
app.use(compression()); // Gzip compression
app.use(express.json({ limit: '1mb' }));

// ==============================================================================
// RATE LIMITING
// ==============================================================================
const apiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100, // 100 requests per 15 minutes per IP
  message: { error: 'Too many requests, please try again later' },
  standardHeaders: true,
  legacyHeaders: false,
});

const authLimiter = rateLimit({
  windowMs: 60 * 60 * 1000, // 1 hour
  max: 5, // 5 auth attempts per hour (prevents brute force)
  skipSuccessfulRequests: true,
  message: { error: 'Too many authentication attempts' },
});

app.use('/api/', apiLimiter);

// ==============================================================================
// AUTHENTICATION MIDDLEWARE
// ==============================================================================
async function authenticate(req, res, next) {
  const authKey = req.headers['x-auth-key'];
  
  if (!authKey || authKey.length !== 64) { // SHA-256 hash is 64 chars
    return res.status(401).json({ error: 'Invalid authentication' });
  }
  
  try {
    // Create user if doesn't exist (auto-registration)
    await pool.query(
      'INSERT INTO users (auth_key_hash) VALUES ($1) ON CONFLICT (auth_key_hash) DO UPDATE SET last_active = NOW()',
      [authKey]
    );
    
    req.authKey = authKey;
    next();
  } catch (err) {
    console.error('Auth error:', err);
    res.status(500).json({ error: 'Authentication failed' });
  }
}

// ==============================================================================
// API ENDPOINTS
// ==============================================================================

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'healthy', timestamp: new Date().toISOString() });
});

// Save progress
app.post('/api/progress', authenticate, async (req, res) => {
  try {
    const { start_date, goal_days, goal_description, check_ins } = req.body;
    
    await pool.query(
      `INSERT INTO progress (auth_key_hash, start_date, goal_days, goal_description, check_ins, updated_at)
       VALUES ($1, $2, $3, $4, $5, NOW())
       ON CONFLICT (auth_key_hash)
       DO UPDATE SET start_date = $2, goal_days = $3, goal_description = $4, check_ins = $5, updated_at = NOW()`,
      [req.authKey, start_date, goal_days, goal_description, JSON.stringify(check_ins || [])]
    );
    
    res.json({ success: true });
  } catch (err) {
    console.error('Save progress error:', err);
    res.status(500).json({ error: 'Failed to save progress' });
  }
});

// Load progress
app.get('/api/progress', authenticate, async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT * FROM progress WHERE auth_key_hash = $1',
      [req.authKey]
    );
    
    if (result.rows.length === 0) {
      return res.json(null);
    }
    
    const row = result.rows[0];
    res.json({
      start_date: row.start_date,
      goal_days: row.goal_days,
      goal_description: row.goal_description,
      check_ins: row.check_ins || [],
    });
  } catch (err) {
    console.error('Load progress error:', err);
    res.status(500).json({ error: 'Failed to load progress' });
  }
});

// Save craving
app.post('/api/cravings', authenticate, async (req, res) => {
  try {
    const { timestamp, intensity, triggers, notes, overcome } = req.body;
    
    await pool.query(
      'INSERT INTO cravings (auth_key_hash, timestamp, intensity, triggers, notes, overcome) VALUES ($1, $2, $3, $4, $5, $6)',
      [req.authKey, timestamp, intensity, JSON.stringify(triggers || []), notes, overcome]
    );
    
    res.json({ success: true });
  } catch (err) {
    console.error('Save craving error:', err);
    res.status(500).json({ error: 'Failed to save craving' });
  }
});

// Load cravings
app.get('/api/cravings', authenticate, async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 1000;
    
    const result = await pool.query(
      'SELECT * FROM cravings WHERE auth_key_hash = $1 ORDER BY timestamp DESC LIMIT $2',
      [req.authKey, limit]
    );
    
    res.json(result.rows.map(row => ({
      timestamp: row.timestamp,
      intensity: row.intensity,
      triggers: row.triggers || [],
      notes: row.notes,
      overcome: row.overcome,
    })));
  } catch (err) {
    console.error('Load cravings error:', err);
    res.status(500).json({ error: 'Failed to load cravings' });
  }
});

// Save challenge progress
app.post('/api/challenges', authenticate, async (req, res) => {
  try {
    const { xp_points, current_challenge_index, last_skip_time } = req.body;
    
    await pool.query(
      `INSERT INTO challenge_progress (auth_key_hash, xp_points, current_challenge_index, last_skip_time, updated_at)
       VALUES ($1, $2, $3, $4, NOW())
       ON CONFLICT (auth_key_hash)
       DO UPDATE SET xp_points = $2, current_challenge_index = $3, last_skip_time = $4, updated_at = NOW()`,
      [req.authKey, xp_points, current_challenge_index, last_skip_time]
    );
    
    res.json({ success: true });
  } catch (err) {
    console.error('Save challenge progress error:', err);
    res.status(500).json({ error: 'Failed to save challenge progress' });
  }
});

// Load challenge progress
app.get('/api/challenges', authenticate, async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT * FROM challenge_progress WHERE auth_key_hash = $1',
      [req.authKey]
    );
    
    if (result.rows.length === 0) {
      return res.json(null);
    }
    
    const row = result.rows[0];
    res.json({
      xp_points: row.xp_points,
      current_challenge_index: row.current_challenge_index,
      last_skip_time: row.last_skip_time,
    });
  } catch (err) {
    console.error('Load challenge progress error:', err);
    res.status(500).json({ error: 'Failed to load challenge progress' });
  }
});

// Full sync endpoint
app.get('/api/sync/full', authenticate, async (req, res) => {
  try {
    const [progressRes, cravingsRes, challengesRes] = await Promise.all([
      pool.query('SELECT * FROM progress WHERE auth_key_hash = $1', [req.authKey]),
      pool.query('SELECT * FROM cravings WHERE auth_key_hash = $1 ORDER BY timestamp DESC LIMIT 1000', [req.authKey]),
      pool.query('SELECT * FROM challenge_progress WHERE auth_key_hash = $1', [req.authKey]),
    ]);
    
    res.json({
      progress: progressRes.rows[0] || null,
      cravings: cravingsRes.rows,
      challenges: challengesRes.rows[0] || null,
      synced_at: new Date().toISOString(),
    });
  } catch (err) {
    console.error('Full sync error:', err);
    res.status(500).json({ error: 'Sync failed' });
  }
});

// Anonymous community messages
app.post('/api/community/message', authLimiter, async (req, res) => {
  try {
    const { message, days_clean, emoji } = req.body;
    
    if (!message || message.length > 500) {
      return res.status(400).json({ error: 'Invalid message' });
    }
    
    await pool.query(
      'INSERT INTO anonymous_messages (message, days_clean, emoji) VALUES ($1, $2, $3)',
      [message, days_clean || 0, emoji || '💪']
    );
    
    res.json({ success: true });
  } catch (err) {
    console.error('Save message error:', err);
    res.status(500).json({ error: 'Failed to save message' });
  }
});

// Load community messages
app.get('/api/community/messages', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 50;
    
    const result = await pool.query(
      'SELECT message, days_clean, emoji, created_at FROM anonymous_messages ORDER BY created_at DESC LIMIT $1',
      [limit]
    );
    
    res.json(result.rows);
  } catch (err) {
    console.error('Load messages error:', err);
    res.status(500).json({ error: 'Failed to load messages' });
  }
});

// ==============================================================================
// START SERVER
// ==============================================================================
app.listen(PORT, () => {
  console.log(`AboutBlank API server running on port ${PORT}`);
  console.log(`Rate limiting: 100 req/15min per IP`);
  console.log(`Connection pool size: 20`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received, closing server...');
  pool.end(() => {
    process.exit(0);
  });
});
