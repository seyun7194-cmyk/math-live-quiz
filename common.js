/* 비례의 전설 · 공통 도구 (선생님·학생 화면이 함께 씀) */
(function () {
  'use strict';

  const cfg = window.APP_CONFIG || {};
  const configured = !!(cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY &&
    !cfg.SUPABASE_URL.includes('YOUR-') && !cfg.SUPABASE_ANON_KEY.includes('YOUR-'));
  const sb = configured && window.supabase
    ? window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
        auth: { persistSession: false, autoRefreshToken: false },
        realtime: { params: { eventsPerSecond: 10 } }
      })
    : null;

  // ---------- 오류 문구 ----------
  const ERRORS = {
    NICKNAME_TAKEN: '같은 방에 같은 별명이 있어요. 다른 별명을 골라 주세요.',
    NICKNAME_DIGITS: '숫자를 4개 넘게 이어 쓸 수 없어요. 전화번호나 번호 대신 별명을 써 주세요.',
    BAD_NICKNAME: '별명은 1~10자로 써 주세요.',
    BAD_ANIMAL: '동물을 하나 골라 주세요.',
    ROOM_NOT_FOUND: '방을 찾을 수 없어요. 방 번호를 다시 확인해 주세요.',
    ROOM_ENDED: '이미 끝난 게임이에요.',
    ROOM_FULL: '방이 가득 찼어요.',
    NOT_AUTHORIZED: '이 방을 만든 선생님 화면에서만 할 수 있어요.',
    NO_PLAYERS: '학생이 1명 이상 들어와야 시작할 수 있어요.',
    ALREADY_STARTED: '이미 시작한 게임이에요.',
    NOT_PLAYING: '게임 중에만 쓸 수 있어요.',
    BAD_TOKEN: '입장 정보가 사라졌어요. 다시 들어와 주세요.'
  };

  async function rpc(name, args) {
    if (!sb) throw Object.assign(new Error('config.js에 Supabase 주소와 키를 넣어 주세요.'), { code: 'NO_CONFIG' });
    const { data, error } = await sb.rpc(name, args || {});
    if (error) {
      const m = (error.message || '').match(/[A-Z][A-Z_]{3,}/);
      const code = m ? m[0] : 'UNKNOWN';
      const e = new Error(ERRORS[code] || '연결이 잠시 불안정해요. 다시 시도해 주세요.');
      e.code = code;
      throw e;
    }
    return data;
  }

  // ---------- 서버 시계 ----------
  let offset = 0;
  async function syncTime() {
    try {
      const t0 = Date.now();
      const st = await rpc('server_time');
      const t1 = Date.now();
      offset = new Date(st).getTime() - (t0 + t1) / 2;
    } catch (e) { /* 다음에 다시 맞춘다 */ }
  }
  function now() { return Date.now() + offset; }
  function ms(ts) { return ts ? new Date(ts).getTime() : 0; }
  function mmss(msLeft) {
    const s = Math.max(0, Math.ceil(msLeft / 1000));
    return String(Math.floor(s / 60)).padStart(2, '0') + ':' + String(s % 60).padStart(2, '0');
  }

  // ---------- 화면 도구 (사용자 글은 항상 글자로만 넣는다) ----------
  function h(tag, props, ...kids) {
    const el = document.createElement(tag);
    if (props) {
      for (const [k, v] of Object.entries(props)) {
        if (v == null || v === false) continue;
        if (k === 'class') el.className = v;
        else if (k === 'text') el.textContent = v;
        else if (k === 'style') el.style.cssText = v;
        else if (k.startsWith('on')) el.addEventListener(k.slice(2).toLowerCase(), v);
        else el.setAttribute(k, v === true ? '' : v);
      }
    }
    for (const kid of kids.flat()) {
      if (kid == null || kid === false) continue;
      el.appendChild(typeof kid === 'string' || typeof kid === 'number' ? document.createTextNode(String(kid)) : kid);
    }
    return el;
  }
  function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }
  function $(sel) { return document.querySelector(sel); }

  // 문제 글: {2/3}, {1 1/2}는 분수 모양으로, \n은 줄바꿈으로
  function frac(n, d) {
    return h('span', { class: 'frac', 'aria-label': d + '분의 ' + n },
      h('span', { class: 'frac-n', text: n }), h('span', { class: 'frac-d', text: d }));
  }
  function renderMath(el, text) {
    clear(el);
    const re = /\{(\d+) (\d+)\/(\d+)\}|\{(\d+)\/(\d+)\}|\n/g;
    let last = 0, m;
    const src = String(text || '');
    while ((m = re.exec(src))) {
      if (m.index > last) el.appendChild(document.createTextNode(src.slice(last, m.index)));
      if (m[0] === '\n') el.appendChild(document.createElement('br'));
      else if (m[1]) el.appendChild(h('span', { class: 'mixed' }, h('span', { class: 'whole', text: m[1] }), frac(m[2], m[3])));
      else el.appendChild(frac(m[4], m[5]));
      last = re.lastIndex;
    }
    if (last < src.length) el.appendChild(document.createTextNode(src.slice(last)));
    return el;
  }
  function mathEl(tag, cls, text) { return renderMath(h(tag, { class: cls }), text); }

  // 그림 카드에 이미 비례식이 크게 나오면, 문제 글 첫 줄의 같은 식은 빼고 보여 준다
  const PROP_LINE = /^[0-9□㉠㉡]+ : [0-9□㉠㉡]+ = [0-9□㉠㉡]+ : [0-9□㉠㉡]+(에서)?$/;
  function questionBody(text, visual) {
    const src = String(text || '');
    if (!visual || visual.kind !== 'prop') return src;
    const lines = src.split('\n');
    return lines.length > 1 && PROP_LINE.test(lines[0].replace(/^비례식 /, '')) ? lines.slice(1).join('\n') : src;
  }

  // 그림 카드 (비례배분 띠, 외항·내항 색 구분)
  function renderVisual(v) {
    if (!v || !v.kind) return null;
    if (v.kind === 'bar') {
      const a = +v.a, b = +v.b, total = a + b, cells = total <= 12;
      const strip = h('div', { class: 'bar-strip' + (cells ? '' : ' bar-strip-wide') });
      if (cells) {
        for (let i = 0; i < total; i++) {
          strip.appendChild(h('div', { class: 'bar-cell ' + (i < a ? 'bar-a' : 'bar-b') },
            i === 0 ? h('span', { text: v.la }) : null,
            i === a ? h('span', { text: v.lb }) : null));
        }
      } else {
        strip.appendChild(h('div', { class: 'bar-cell bar-a', style: 'flex:' + a }, h('span', { text: v.la })));
        strip.appendChild(h('div', { class: 'bar-cell bar-b', style: 'flex:' + b }, h('span', { text: v.lb })));
      }
      return h('div', { class: 'pic-card' },
        h('div', { class: 'pic-top' }, h('span', { text: '전체' }), h('span', { class: 'num', text: v.total })),
        strip,
        h('div', { class: 'pic-foot' }, h('span', { text: (v.la || '') + ' : ' + (v.lb || '') + ' = ' }), h('span', { class: 'num big', text: a + ' : ' + b })));
    }
    if (v.kind === 'prop') {
      const t = v.terms || [];
      const term = (x, cls) => h('span', { class: 'term ' + cls, text: x });
      return h('div', { class: 'pic-card' },
        h('div', { class: 'prop-line num' }, term(t[0], 'outer'), ' : ', term(t[1], 'inner'), ' = ', term(t[2], 'inner'), ' : ', term(t[3], 'outer')),
        h('div', { class: 'legend' },
          h('span', null, h('i', { class: 'sw outer' }), '외항'),
          h('span', null, h('i', { class: 'sw inner' }), '내항')));
    }
    return null;
  }

  // ---------- 동물 아바타 ----------
  const S = 'stroke="#2E2A5A" stroke-width="1.4"';
  const EYES = '<circle cx="11" cy="16" r="1.3" fill="#2E2A5A"/><circle cx="17" cy="16" r="1.3" fill="#2E2A5A"/>';
  const SMILE = '<path d="M12.5 20 Q14 21.4 15.5 20" stroke="#2E2A5A" stroke-width="1.3" fill="none" stroke-linecap="round"/>';
  const FACE = (fill) => `<circle cx="14" cy="17" r="9" fill="${fill}" ${S}/>`;
  const ANIMALS = [
    { id: 'rabbit', name: '토끼', bg: '#FFE08A',
      svg: `<ellipse cx="10" cy="7" rx="2.6" ry="6.5" fill="#fff" ${S}/><ellipse cx="18" cy="7" rx="2.6" ry="6.5" fill="#fff" ${S}/>${FACE('#fff')}${EYES}${SMILE}` },
    { id: 'cat', name: '고양이', bg: '#BFE0F7',
      svg: `<path d="M6 6 L11 11 L6 13 Z" fill="#fff" ${S} stroke-linejoin="round"/><path d="M22 6 L17 11 L22 13 Z" fill="#fff" ${S} stroke-linejoin="round"/>${FACE('#fff')}${EYES}${SMILE}<path d="M4 18 L8 18.5 M4 21 L8 20" stroke="#2E2A5A" stroke-width="1"/><path d="M24 18 L20 18.5 M24 21 L20 20" stroke="#2E2A5A" stroke-width="1"/>` },
    { id: 'bear', name: '곰', bg: '#FFC3CF',
      svg: `<circle cx="7.5" cy="9.5" r="3.5" fill="#E9C9A8" ${S}/><circle cx="20.5" cy="9.5" r="3.5" fill="#E9C9A8" ${S}/>${FACE('#E9C9A8')}<ellipse cx="14" cy="20" rx="3.6" ry="2.6" fill="#fff" ${S}/>${EYES}<circle cx="14" cy="19.2" r="1" fill="#2E2A5A"/>` },
    { id: 'fox', name: '여우', bg: '#FFE08A',
      svg: `<path d="M5 5 L11 10 L6 14 Z" fill="#FFB27A" ${S} stroke-linejoin="round"/><path d="M23 5 L17 10 L22 14 Z" fill="#FFB27A" ${S} stroke-linejoin="round"/>${FACE('#FFB27A')}<path d="M8 19 Q14 27 20 19 Q14 22 8 19 Z" fill="#fff"/>${EYES}<circle cx="14" cy="20.5" r="1" fill="#2E2A5A"/>` },
    { id: 'penguin', name: '펭귄', bg: '#BFE0F7',
      svg: `${FACE('#3B3770')}<ellipse cx="14" cy="18.5" rx="6.3" ry="6" fill="#fff"/>${EYES}<path d="M12.6 19.5 L15.4 19.5 L14 21.3 Z" fill="#FFB547"/>` },
    { id: 'squirrel', name: '다람쥐', bg: '#FFC3CF',
      svg: `<circle cx="8" cy="9" r="2.8" fill="#D9A877" ${S}/><circle cx="20" cy="9" r="2.8" fill="#D9A877" ${S}/>${FACE('#D9A877')}<circle cx="9" cy="20" r="1.8" fill="#FFB3C1"/><circle cx="19" cy="20" r="1.8" fill="#FFB3C1"/>${EYES}${SMILE}` },
    { id: 'frog', name: '개구리', bg: '#FFE08A',
      svg: `<circle cx="9.5" cy="9.5" r="3.6" fill="#A8E0B5" ${S}/><circle cx="18.5" cy="9.5" r="3.6" fill="#A8E0B5" ${S}/>${FACE('#A8E0B5')}<circle cx="9.5" cy="9.5" r="1.4" fill="#2E2A5A"/><circle cx="18.5" cy="9.5" r="1.4" fill="#2E2A5A"/><path d="M9.5 19 Q14 23 18.5 19" stroke="#2E2A5A" stroke-width="1.3" fill="none" stroke-linecap="round"/>` },
    { id: 'owl', name: '부엉이', bg: '#BFE0F7',
      svg: `<path d="M6 8 L9 12 L6 13 Z M22 8 L19 12 L22 13 Z" fill="#B9ADF6" ${S} stroke-linejoin="round"/>${FACE('#B9ADF6')}<circle cx="10.8" cy="16" r="3" fill="#fff" ${S}/><circle cx="17.2" cy="16" r="3" fill="#fff" ${S}/><circle cx="10.8" cy="16" r="1.2" fill="#2E2A5A"/><circle cx="17.2" cy="16" r="1.2" fill="#2E2A5A"/><path d="M12.8 19.5 L15.2 19.5 L14 21.6 Z" fill="#FFB547"/>` }
  ];
  const ANIMAL_BY_ID = Object.fromEntries(ANIMALS.map(a => [a.id, a]));
  function avatar(id, size) {
    const a = ANIMAL_BY_ID[id] || ANIMALS[0];
    const px = size || 40;
    const wrap = h('span', { class: 'avatar', style: `width:${px}px;height:${px}px;background:${a.bg}`, 'aria-hidden': 'true' });
    // 고정된 그림 문자열만 넣는다(사용자 입력 없음)
    wrap.innerHTML = `<svg viewBox="0 0 28 28" width="${Math.round(px * 0.72)}" height="${Math.round(px * 0.72)}">${a.svg}</svg>`;
    return wrap;
  }

  // ---------- 순위: 점수 → 맞힌 수 → 먼저 들어온 순서 ----------
  function rankPlayers(list) {
    return [...list]
      .sort((a, b) => (b.score - a.score) || (b.correct - a.correct) || (ms(a.joined_at) - ms(b.joined_at)))
      .map((p, i) => Object.assign({}, p, { rank: i + 1 }));
  }

  const LEVELS = [
    { n: 1, name: '기초', desc: '용어와 성질 알기 · O/X와 4지선다', sample: '7 : 4에서 전항은 무엇일까요?' },
    { n: 2, name: '유형 연습', desc: '□ 구하기 · 간단한 자연수의 비 · 비례배분', sample: '48 : 36을 간단한 자연수의 비로 나타내면?' },
    { n: 3, name: '응용 심화', desc: '분수·소수가 섞인 비 · 문장제', sample: '실제 300 m를 지도에 5 cm로 그렸어요. 12 cm는?' },
    { n: 4, name: '고난도', desc: '조건이 두 개 · 거꾸로 생각하기', sample: '둘레 210 cm, 가로와 세로의 비 3 : 4일 때 세로는?' }
  ];
  const TYPE_NAMES = {
    A1: '전항·후항', A2: '외항·내항', A3: '비의 성질 O/X', A4: '같은 수 곱하기', A5: '비율이 같은 비',
    A6: '비례식 O/X', A7: '비례식의 성질 O/X', A8: '용어 고르기',
    B1: '□ 구하기 (비의 성질)', B2: '자연수의 비 간단히', B3: '소수의 비', B4: '분수의 비',
    B5: '□ 구하기 (비례식의 성질)', B6: '비례배분',
    C1: '분수와 소수의 비', C2: '대분수가 있는 비', C3: '비례식 세우기', C4: '□ 구하기 (분수)',
    C5: '비례식 활용', C6: '톱니바퀴·속력', C7: '비례배분 문장제', C8: '지도 거리',
    D1: '외항의 곱', D2: '둘레와 비', D3: '조리법 두 단계', D4: '부분에서 전체', D5: '비례배분 뒤 차', D6: '합이 주어진 비례식'
  };

  // ---------- 실시간 + 끊기면 자동 새로고침 (PRD 9절) ----------
  function watch({ name, subs, reload, onMode }) {
    let mode = 'connecting', pollTimer = null, stopped = false;
    const setMode = (m) => { if (mode !== m) { mode = m; onMode && onMode(m); } };
    const startPoll = () => {
      if (pollTimer || stopped) return;
      setMode('poll');
      const loop = async () => {
        if (stopped) return;
        try { await reload(); } catch (e) { /* 다음 차례에 다시 */ }
        pollTimer = setTimeout(loop, 1500 + Math.random() * 500);
      };
      loop();
    };
    const stopPoll = () => { clearTimeout(pollTimer); pollTimer = null; };
    let ch = null;
    if (sb) {
      ch = sb.channel(name);
      subs.forEach(s => ch.on('postgres_changes', { event: '*', schema: 'public', table: s.table, filter: s.filter }, s.cb));
      ch.subscribe((status) => {
        if (status === 'SUBSCRIBED') { stopPoll(); setMode('live'); reload().catch(() => {}); }
        else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') startPoll();
      });
    }
    const fallback = setTimeout(() => { if (mode !== 'live') startPoll(); }, 6000);
    const full = setInterval(() => { if (!stopped) reload().catch(() => {}); }, 10000);
    return () => { stopped = true; clearTimeout(fallback); clearInterval(full); stopPoll(); if (ch) sb.removeChannel(ch); };
  }

  // ---------- 저장소 ----------
  function store(kind, key) {
    const s = () => { try { return kind === 'local' ? window.localStorage : window.sessionStorage; } catch (e) { return null; } };
    return {
      get() { try { return JSON.parse(s().getItem(key)); } catch (e) { return null; } },
      set(v) { try { s().setItem(key, JSON.stringify(v)); } catch (e) { /* 저장 못 해도 계속 */ } },
      clear() { try { s().removeItem(key); } catch (e) { /* 무시 */ } }
    };
  }

  // ---------- 알림 띠 ----------
  let toastTimer = null;
  function toast(msg) {
    let el = $('#toast');
    if (!el) { el = h('div', { id: 'toast', class: 'toast', role: 'status', 'aria-live': 'polite' }); document.body.appendChild(el); }
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('show'), 3200);
  }

  const reducedMotion = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);

  function configWarning() {
    if (configured) return false;
    document.body.appendChild(h('div', { class: 'config-warning glass' },
      h('strong', { text: '설정이 필요해요' }),
      h('p', { text: 'config.js 파일에 Supabase 프로젝트 주소와 anon 키를 넣은 뒤 다시 배포해 주세요. 자세한 순서는 README.md에 있어요.' })));
    return true;
  }

  window.App = {
    sb, configured, rpc, syncTime, now, ms, mmss, h, clear, $, renderMath, mathEl, renderVisual, questionBody,
    ANIMALS, avatar, rankPlayers, LEVELS, TYPE_NAMES, watch, store, toast, reducedMotion, configWarning
  };
})();
