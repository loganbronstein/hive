#!/usr/bin/env node
// Jarvis Dispatcher Monitor Server v2
// Serves dashboard UI, REST API, and WebSocket for real-time updates
// Run: node server.js (default port 3939)

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { WebSocketServer } = require('ws');

const PORT = process.env.DISPATCHER_PORT || 3939;
const DISPATCHER_DIR = path.join(process.env.HOME, '.claude', 'dispatcher');
const LOG_FILE = path.join(DISPATCHER_DIR, 'dispatcher.log');
const QUEUE_FILE = path.join(DISPATCHER_DIR, 'task-queue.md');
const PROMPTS_DIR = path.join(DISPATCHER_DIR, 'worker-prompts');

// ============================================================
// DATA COLLECTION
// ============================================================

function getWorkers() {
    try {
        const output = execSync('tmux list-sessions -F "#{session_name}" 2>/dev/null || true', {
            encoding: 'utf8', timeout: 5000
        }).trim();

        if (!output) return [];

        return output.split('\n')
            .filter(s => s.startsWith('worker-'))
            .map(session => {
                const rawName = session.replace('worker-', '');
                const displayName = rawName.replace(/-/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
                let termOutput = '';
                let status = 'IDLE';
                let progress = null;
                let progressText = '';
                let statusText = 'Waiting for task...';
                let startTime = null;

                try {
                    termOutput = execSync(`tmux capture-pane -t "${session}" -p -S -40 2>/dev/null || true`, {
                        encoding: 'utf8', timeout: 5000
                    }).trim();

                    const lines = termOutput.split('\n');
                    for (let i = lines.length - 1; i >= 0; i--) {
                        const line = lines[i].trim();
                        if (line.includes('DONE:')) {
                            status = 'DONE';
                            statusText = line.replace(/.*DONE:\s*/, '');
                            break;
                        }
                        if (line.includes('BLOCKED:')) {
                            status = 'BLOCKED';
                            statusText = line.replace(/.*BLOCKED:\s*/, '');
                            break;
                        }
                        if (line.includes('ERROR:')) {
                            status = 'ERROR';
                            statusText = line.replace(/.*ERROR:\s*/, '');
                            break;
                        }
                        if (line.includes('PROGRESS:')) {
                            status = 'WORKING';
                            progressText = line.replace(/.*PROGRESS:\s*/, '');
                            const match = line.match(/(\d+)\/(\d+)/);
                            if (match) {
                                progress = Math.round((parseInt(match[1]) / parseInt(match[2])) * 100);
                            }
                            statusText = progressText;
                            break;
                        }
                    }

                    if (status === 'IDLE' && termOutput.length > 50) {
                        status = 'WORKING';
                        statusText = 'Processing...';
                    }
                } catch (e) {
                    status = 'ERROR';
                    statusText = 'Cannot read terminal output';
                }

                // Get last 15 lines for display
                const displayLines = termOutput.split('\n').slice(-15).join('\n');

                return {
                    id: rawName,
                    name: displayName,
                    status,
                    statusText,
                    progress,
                    output: displayLines,
                    startTime
                };
            });
    } catch (e) {
        return [];
    }
}

function getLog() {
    try {
        if (!fs.existsSync(LOG_FILE)) return [];
        const content = fs.readFileSync(LOG_FILE, 'utf8');
        const lines = content.trim().split('\n').filter(l => l.length > 0);

        return lines.slice(-100).map(line => {
            const match = line.match(/\[(.+?)\] \[(.+?)\] (.+)/);
            if (match) {
                return {
                    time: match[1],
                    level: match[2].toLowerCase(),
                    message: match[3]
                };
            }
            return { time: '', level: 'info', message: line };
        });
    } catch (e) {
        return [];
    }
}

function getTaskQueue() {
    try {
        if (!fs.existsSync(QUEUE_FILE)) return { active: [], pending: [], completed: [], failed: [] };

        const content = fs.readFileSync(QUEUE_FILE, 'utf8');
        const tasks = { active: [], pending: [], completed: [], failed: [] };
        let currentSection = 'pending';

        content.split('\n').forEach(line => {
            const trimmed = line.trim();
            if (trimmed.startsWith('## Active')) currentSection = 'active';
            else if (trimmed.startsWith('## Pending')) currentSection = 'pending';
            else if (trimmed.startsWith('## Completed')) currentSection = 'completed';
            else if (trimmed.startsWith('## Failed')) currentSection = 'failed';
            else if (trimmed.startsWith('- [')) {
                const isChecked = trimmed.startsWith('- [x]');
                const isFailed = trimmed.startsWith('- [-]');
                const isInProgress = trimmed.startsWith('- [~]');
                const text = trimmed.replace(/^- \[.\] /, '');

                const task = { text, raw: trimmed };

                if (isChecked) tasks.completed.push(task);
                else if (isFailed) tasks.failed.push(task);
                else if (isInProgress) tasks.active.push(task);
                else tasks.pending.push(task);
            }
        });

        return tasks;
    } catch (e) {
        return { active: [], pending: [], completed: [], failed: [] };
    }
}

function getWorkerHistory() {
    try {
        if (!fs.existsSync(PROMPTS_DIR)) return [];
        const files = fs.readdirSync(PROMPTS_DIR)
            .filter(f => f.endsWith('.md'))
            .sort()
            .reverse()
            .slice(0, 50);

        return files.map(f => {
            const content = fs.readFileSync(path.join(PROMPTS_DIR, f), 'utf8');
            const match = f.match(/(.+?)-(\d{8}-\d{6})\.md/);
            return {
                worker: match ? match[1] : f,
                timestamp: match ? match[2] : '',
                prompt: content.substring(0, 200) + (content.length > 200 ? '...' : ''),
                file: f
            };
        });
    } catch (e) {
        return [];
    }
}

function getFullStatus() {
    const workers = getWorkers();
    const tasks = getTaskQueue();
    const totalTasks = tasks.active.length + tasks.pending.length + tasks.completed.length + tasks.failed.length;
    const completedCount = tasks.completed.length;
    const progressPct = totalTasks > 0 ? Math.round((completedCount / totalTasks) * 100) : 0;

    return {
        workers,
        tasks,
        log: getLog(),
        history: getWorkerHistory(),
        summary: {
            totalWorkers: workers.length,
            working: workers.filter(w => w.status === 'WORKING').length,
            done: workers.filter(w => w.status === 'DONE').length,
            blocked: workers.filter(w => w.status === 'BLOCKED').length,
            errors: workers.filter(w => w.status === 'ERROR').length,
            totalTasks,
            completedTasks: completedCount,
            projectProgress: progressPct
        },
        timestamp: new Date().toISOString()
    };
}

// ============================================================
// HTTP SERVER
// ============================================================

const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://localhost:${PORT}`);

    // CORS headers
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST');

    if (url.pathname === '/api/status') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(getFullStatus()));
    } else if (url.pathname === '/api/workers') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(getWorkers()));
    } else if (url.pathname === '/api/tasks') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(getTaskQueue()));
    } else if (url.pathname === '/api/log') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(getLog()));
    } else if (url.pathname === '/api/history') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(getWorkerHistory()));
    } else if (url.pathname === '/api/worker-output' && url.searchParams.get('name')) {
        const name = url.searchParams.get('name');
        try {
            const output = execSync(`tmux capture-pane -t "worker-${name}" -p -S -100 2>/dev/null || true`, {
                encoding: 'utf8', timeout: 5000
            });
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ name, output }));
        } catch (e) {
            res.writeHead(404, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Worker not found' }));
        }
    } else if (url.pathname === '/' || url.pathname === '/index.html') {
        const htmlPath = path.join(__dirname, 'index.html');
        fs.readFile(htmlPath, (err, data) => {
            if (err) {
                res.writeHead(500);
                res.end('Error loading dashboard');
                return;
            }
            res.writeHead(200, { 'Content-Type': 'text/html' });
            res.end(data);
        });
    } else {
        res.writeHead(404);
        res.end('Not found');
    }
});

// ============================================================
// WEBSOCKET SERVER
// ============================================================

const wss = new WebSocketServer({ server });

wss.on('connection', (ws) => {
    // Send initial state
    ws.send(JSON.stringify({ type: 'init', data: getFullStatus() }));

    // Set up periodic updates
    const interval = setInterval(() => {
        if (ws.readyState === ws.OPEN) {
            ws.send(JSON.stringify({ type: 'update', data: getFullStatus() }));
        }
    }, 3000);

    ws.on('close', () => clearInterval(interval));
});

// ============================================================
// START
// ============================================================

server.listen(PORT, () => {
    console.log(`Jarvis Dispatcher Monitor v2 running at http://localhost:${PORT}`);
    console.log(`WebSocket available at ws://localhost:${PORT}`);
});
