#!/usr/bin/env node
/**
 * 监管打卡 App —— 本地服务器
 *
 * ## 为什么需要一个服务器
 *
 * 如果只用浏览器 localStorage，手机和电脑各存一份数据，永远对不上。
 * 「用一个 App 监督自己」的前提是**两台设备看到的是同一份记录**，所以数据必须放在
 * 一个共享的地方。这个脚本就提供那个地方：一个 JSON 文件 + 一个 HTTP 接口。
 *
 * ## 为什么不用框架
 *
 * 整个应用只有一个人用、数据量极小。用 Express 之类的框架只会多一个装依赖的步骤，
 * 而这个项目的第一原则是"队友克隆下来就能跑"。所以只用 Node 自带模块，零依赖。
 *
 * ## 数据放在哪
 *
 *   data.json   —— 就在本脚本旁边，纯文本，可以直接用 VS Code 打开看/改/备份
 *
 * 写入用"临时文件 + rename"的原子写法：写到一半断电也不会把原文件损坏。
 *
 * 用法：
 *   node tools/checkin/server.js
 *   node tools/checkin/server.js --port 8090
 */

'use strict';

const http = require('node:http');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');

// ------------------------------------------------------------------ 配置

const PORT = Number(argValue('--port') || process.env.PORT || 8080);
const HOST = '0.0.0.0'; // 绑 0.0.0.0 手机才能连进来；只绑 127.0.0.1 的话手机访问不到

const ROOT = __dirname;
const PUBLIC_DIR = path.join(ROOT, 'public');
const DATA_FILE = path.join(ROOT, 'data.json');
const DATA_TMP = DATA_FILE + '.tmp';

/** 单次请求体上限。打卡数据很小，2MB 绰绰有余，同时防止有人误传大文件把内存打爆。 */
const MAX_BODY = 2 * 1024 * 1024;

// ------------------------------------------------------------------ 默认清单

/**
 * 首次运行时写入的默认清单。
 *
 * 内容就是 docs/02 和 docs/03 里"监管每天该做什么"的浓缩版 —— 让 App 一打开就有东西可打卡，
 * 而不是一个空列表让人不知道填什么。所有条目都可以在界面上改/删/加。
 */
function defaultItems() {
    return [
        // ---- 每日 ----
        { id: 'd1', sheet: '每日', text: '跑了 git diff --stat，改动文件数 ≤ 3', order: 0 },
        { id: 'd2', sheet: '每日', text: '逐行看过今天的 diff（不是只看结论行）', order: 1 },
        { id: 'd3', sheet: '每日', text: '跑了 tools\\verify.ps1，退出码是 0', order: 2 },
        { id: 'd4', sheet: '每日', text: '测试数量没掉（225 / 1407 / 96）', order: 3 },
        { id: 'd5', sheet: '每日', text: '开窗口亲手玩过一次', order: 4 },
        { id: 'd6', sheet: '每日', text: '改了 data/*.json 就在游戏里 check 过没有 ✗', order: 5 },
        { id: 'd7', sheet: '每日', text: '今天有没有「AI 说通过但实际不对」？记下来了', order: 6 },
        // ---- 每周 ----
        { id: 'w1', sheet: '每周', text: '新写了 ≥ 1 条验收用例（含反向用例）', order: 0 },
        { id: 'w2', sheet: '每周', text: '复盘：本周抓到几次「假通过」，怎么抓到的', order: 1 },
        { id: 'w3', sheet: '每周', text: '确认每次让 AI 动手前都有 commit 回退点', order: 2 },
    ];
}

// ------------------------------------------------------------------ 状态读写

let state = null;

function defaultState() {
    return { version: 1, rev: 0, items: defaultItems(), days: {} };
}

function loadState() {
    if (!fs.existsSync(DATA_FILE)) {
        state = defaultState();
        // 首次运行马上落盘，这样用户能在 VS Code 里看到文件长什么样
        saveStateSync();
        return;
    }
    try {
        const raw = fs.readFileSync(DATA_FILE, 'utf8');
        const parsed = JSON.parse(raw);
        // 容错：文件被手工改坏了也不要崩，退回到默认状态
        state = {
            version: 1,
            rev: Number(parsed.rev) || 0,
            items: Array.isArray(parsed.items) ? parsed.items : defaultItems(),
            days: parsed.days && typeof parsed.days === 'object' ? parsed.days : {},
        };
    } catch (err) {
        console.error(`[警告] data.json 解析失败，先备份再看：${err.message}`);
        const backup = DATA_FILE + '.broken-' + Date.now();
        try { fs.copyFileSync(DATA_FILE, backup); console.error(`        已备份到 ${backup}`); } catch { }
        state = defaultState();
    }
}

/** 同步写，只在启动时用。 */
function saveStateSync() {
    fs.writeFileSync(DATA_TMP, JSON.stringify(state, null, 2), 'utf8');
    fs.renameSync(DATA_TMP, DATA_FILE);
}

/**
 * 写状态到磁盘。
 *
 * 串行化：把所有写操作挂到一条 Promise 链上。
 * 不这么做的话，两个设备几乎同时提交时，两个 rename 可能交错，
 * 后一个覆盖前一个 —— 表现是"刚打的卡莫名其妙没了"。
 */
let writeChain = Promise.resolve();
function saveState() {
    writeChain = writeChain.then(async () => {
        await fsp.writeFile(DATA_TMP, JSON.stringify(state, null, 2), 'utf8');
        await fsp.rename(DATA_TMP, DATA_FILE);
    }).catch((err) => {
        console.error('[错误] 写盘失败：', err.message);
    });
    return writeChain;
}

// ------------------------------------------------------------------ HTTP 工具

function sendJson(res, code, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(code, {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': Buffer.byteLength(body),
        // 打卡数据不能被浏览器缓存，否则两台设备会各自看到旧数据
        'Cache-Control': 'no-store',
    });
    res.end(body);
}

function readBody(req) {
    return new Promise((resolve, reject) => {
        let size = 0;
        const chunks = [];
        req.on('data', (c) => {
            size += c.length;
            if (size > MAX_BODY) {
                reject(new Error('请求体过大'));
                req.destroy();
                return;
            }
            chunks.push(c);
        });
        req.on('end', () => {
            const text = Buffer.concat(chunks).toString('utf8');
            if (!text) return resolve({});
            try { resolve(JSON.parse(text)); }
            catch (err) { reject(new Error('JSON 解析失败：' + err.message)); }
        });
        req.on('error', reject);
    });
}

const MIME = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.ico': 'image/x-icon',
    '.webmanifest': 'application/manifest+json',
};

function serveStatic(res, urlPath) {
    // 路径穿越防护：只允许访问 public/ 里面，且不允许 .. 往上跳
    const rel = decodeURIComponent(urlPath === '/' ? '/index.html' : urlPath);
    const target = path.normalize(path.join(PUBLIC_DIR, rel));
    if (!target.startsWith(PUBLIC_DIR)) {
        res.writeHead(403); res.end('forbidden'); return;
    }
    fs.readFile(target, (err, buf) => {
        if (err) { res.writeHead(404); res.end('not found'); return; }
        res.writeHead(200, {
            'Content-Type': MIME[path.extname(target).toLowerCase()] || 'application/octet-stream',
            'Content-Length': buf.length,
            'Cache-Control': 'no-cache',
        });
        res.end(buf);
    });
}

// ------------------------------------------------------------------ 路由

async function handleApi(req, res, url) {
    const p = url.pathname;

    // 取全量状态
    if (req.method === 'GET' && p === '/api/state') {
        return sendJson(res, 200, state);
    }

    // 只更新某一天（打卡/取消）
    //
    // 刻意做成"按天提交"而不是"提交整个状态"：
    // 两台设备同时操作时，只提交自己动过的那一天，就不会互相覆盖。
    // 如果提交整份状态，手机和电脑几乎同时打卡就会丢数据。
    if (req.method === 'POST' && p === '/api/day') {
        const body = await readBody(req);
        const date = body && body.date;
        if (typeof date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
            return sendJson(res, 400, { error: 'date 必须是 YYYY-MM-DD' });
        }
        const done = Array.isArray(body.done) ? body.done.filter((x) => typeof x === 'string') : [];
        const note = typeof body.note === 'string' ? body.note : '';
        state.days[date] = { done, note };
        state.rev++;
        await saveState();
        return sendJson(res, 200, { ok: true, rev: state.rev, day: state.days[date] });
    }

    // 替换清单（增删改条目）
    if (req.method === 'POST' && p === '/api/items') {
        const body = await readBody(req);
        if (!Array.isArray(body.items)) {
            return sendJson(res, 400, { error: 'items 必须是数组' });
        }
        state.items = body.items
            .filter((it) => it && typeof it.text === 'string' && it.text.trim())
            .map((it, i) => ({
                id: typeof it.id === 'string' && it.id ? it.id : 'i' + Date.now() + '_' + i,
                sheet: typeof it.sheet === 'string' && it.sheet ? it.sheet : '每日',
                text: String(it.text).slice(0, 200),
                order: Number.isFinite(it.order) ? it.order : i,
            }));
        state.rev++;
        await saveState();
        return sendJson(res, 200, { ok: true, rev: state.rev, items: state.items });
    }

    // 导入整份备份
    if (req.method === 'POST' && p === '/api/import') {
        const body = await readBody(req);
        if (!Array.isArray(body.items)) {
            return sendJson(res, 400, { error: '导入文件格式不对：缺少 items' });
        }
        state = {
            version: 1,
            rev: (Number(body.rev) || 0) + 1,
            items: body.items,
            days: body.days && typeof body.days === 'object' ? body.days : {},
        };
        await saveState();
        return sendJson(res, 200, { ok: true, rev: state.rev });
    }

    res.writeHead(404); res.end('no such api');
}

// ------------------------------------------------------------------ 启动

const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

    const task = url.pathname.startsWith('/api/')
        ? handleApi(req, res, url)
        : Promise.resolve(serveStatic(res, url.pathname));

    task.catch((err) => {
        console.error('[请求出错]', err.message);
        if (!res.headersSent) sendJson(res, 400, { error: err.message });
        else res.end();
    });
});

/** 取本机局域网 IP，打印给用户，手机要用这个。 */
function lanAddresses() {
    const out = [];
    for (const list of Object.values(os.networkInterfaces())) {
        for (const ni of list || []) {
            if (ni.family === 'IPv4' && !ni.internal) out.push(ni.address);
        }
    }
    return out;
}

function argValue(flag) {
    const i = process.argv.indexOf(flag);
    return i >= 0 ? process.argv[i + 1] : null;
}

loadState();

server.listen(PORT, HOST, () => {
    const lines = [
        '',
        '  监管打卡 App 已启动',
        '  ' + '-'.repeat(46),
        `  本机（电脑）：  http://localhost:${PORT}`,
    ];
    for (const ip of lanAddresses()) {
        lines.push(`  手机/平板：     http://${ip}:${PORT}`);
    }
    lines.push(
        '  ' + '-'.repeat(46),
        `  数据文件：      ${DATA_FILE}`,
        '  停止：          Ctrl+C',
        ''
    );
    console.log(lines.join('\n'));
});

process.on('SIGINT', () => {
    console.log('\n正在保存并退出…');
    try { saveStateSync(); } catch { }
    process.exit(0);
});
