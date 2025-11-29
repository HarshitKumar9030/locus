const express = require('express');
const sqlite3 = require('sqlite3').verbose();
const cors = require('cors');
const bodyParser = require('body-parser');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(bodyParser.json());
app.use(express.static(path.join(__dirname, 'public')));

// Database Setup
const db = new sqlite3.Database('./locus.db', (err) => {
    if (err) {
        console.error('Error opening database', err.message);
    } else {
        console.log('Connected to the SQLite database.');
        db.run(`CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            deviceId TEXT,
            startTime INTEGER,
            endTime INTEGER,
            isActive INTEGER
        )`);
        db.run(`CREATE TABLE IF NOT EXISTS locations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sessionId TEXT,
            latitude REAL,
            longitude REAL,
            timestamp INTEGER,
            FOREIGN KEY(sessionId) REFERENCES sessions(id)
        )`);
    }
});

// API Endpoints

// Start a session
app.post('/api/session/start', (req, res) => {
    const { deviceId, duration } = req.body;
    const sessionId = `${deviceId}-${Date.now()}`;
    const startTime = Date.now();
    const endTime = startTime + (duration || 12 * 60 * 60 * 1000); // Default 12 hours

    db.run(`INSERT INTO sessions (id, deviceId, startTime, endTime, isActive) VALUES (?, ?, ?, ?, ?)`,
        [sessionId, deviceId, startTime, endTime, 1],
        function(err) {
            if (err) {
                return res.status(500).json({ error: err.message });
            }
            res.json({ sessionId, startTime, endTime });
        }
    );
});

// Stop a session
app.post('/api/session/stop', (req, res) => {
    const { sessionId } = req.body;
    db.run(`UPDATE sessions SET isActive = 0 WHERE id = ?`, [sessionId], function(err) {
        if (err) {
            return res.status(500).json({ error: err.message });
        }
        res.json({ message: 'Session stopped' });
    });
});

// Report location (Single or Batch)
app.post('/api/location', (req, res) => {
    const body = req.body;
    
    // Normalize to array
    const locations = Array.isArray(body) ? body : [body];

    if (locations.length === 0) return res.json({ message: 'No data' });

    const sessionId = locations[0].sessionId;

    // Check session validity once
    db.get(`SELECT isActive, endTime FROM sessions WHERE id = ?`, [sessionId], (err, row) => {
        if (err) return res.status(500).json({ error: err.message });
        if (!row) return res.status(404).json({ error: 'Session not found' });
        
        // We allow posting late data if it was recorded during the session, 
        // but for simplicity, we just check if the session *was* valid.
        // If the session is technically "over" by time but we are syncing old data, that's fine.
        // But if the session was manually stopped (isActive=0), we might still want to accept the data 
        // if it belongs to that session. 
        // Let's just check if session exists.

        const stmt = db.prepare(`INSERT INTO locations (sessionId, latitude, longitude, timestamp) VALUES (?, ?, ?, ?)`);
        
        db.serialize(() => {
            db.run("BEGIN TRANSACTION");
            locations.forEach(loc => {
                stmt.run(sessionId, loc.latitude, loc.longitude, loc.timestamp || Date.now());
            });
            db.run("COMMIT", (err) => {
                if (err) {
                    console.error("Transaction error:", err);
                    return res.status(500).json({ error: err.message });
                }
                res.json({ message: `Recorded ${locations.length} locations` });
            });
        });
        stmt.finalize();
    });
});

// Get all sessions
app.get('/api/sessions', (req, res) => {
    db.all(`SELECT * FROM sessions ORDER BY startTime DESC`, [], (err, rows) => {
        if (err) {
            return res.status(500).json({ error: err.message });
        }
        res.json(rows);
    });
});

// Get locations for a session
app.get('/api/session/:id/locations', (req, res) => {
    const sessionId = req.params.id;
    db.all(`SELECT * FROM locations WHERE sessionId = ? ORDER BY timestamp ASC`, [sessionId], (err, rows) => {
        if (err) {
            return res.status(500).json({ error: err.message });
        }
        res.json(rows);
    });
});

app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});
