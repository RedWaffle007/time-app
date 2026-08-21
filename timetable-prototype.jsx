import React, { useState, useEffect, useRef } from "react";
import { Clock, Bell, Plus, MessageCircle, BarChart3, Check, Sparkles, ChevronRight, Sun, Moon, Sunrise, Send } from "lucide-react";

// ── Time-reactive sky ──────────────────────────────────────────────────
// Instead of 4 hard buckets, the sky is a continuous model driven by a
// fractional hour (0–24). Gradients are keyframed against real sky colors
// (deep night → dawn glow → clear day → golden hour → dusk → night), and
// a sun or moon arcs across the sky along a true rising/setting path.

const lerp = (a, b, t) => a + (b - a) * t;
const hexToRgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
const rgbToHex = (r, g, b) => "#" + [r, g, b].map((v) => Math.round(v).toString(16).padStart(2, "0")).join("");
const mix = (h1, h2, t) => {
  const a = hexToRgb(h1), b = hexToRgb(h2);
  return rgbToHex(lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t));
};

// Real-ish sky keyframes: [top, mid, bottom] sampled every few hours.
const SKY_KEYS = [
  { h: 0,  top: "#05060F", mid: "#0B1026", bot: "#141A3A" }, // deep night
  { h: 5,  top: "#12183A", mid: "#3A2E5A", bot: "#7B4B6E" }, // first light
  { h: 6.5,top: "#5A6BA8", mid: "#E8896B", bot: "#FFC48C" }, // sunrise glow
  { h: 9,  top: "#5AA6E0", mid: "#8Fc7EC", bot: "#CDE8F5" }, // clear morning
  { h: 13, top: "#3E86D6", mid: "#6FB0E8", bot: "#BFE0F2" }, // bright midday
  { h: 17, top: "#4E82C4", mid: "#9CB6D8", bot: "#E7D9B8" }, // late afternoon
  { h: 18.5,top:"#3C4E8C", mid: "#C1665F", bot: "#F5A65B" }, // golden hour
  { h: 20, top: "#1E2450", mid: "#5B3A6E", bot: "#C46A6A" }, // dusk
  { h: 21.5,top:"#0C1030", mid: "#231A44", bot: "#3A2A55" }, // twilight
  { h: 24, top: "#05060F", mid: "#0B1026", bot: "#141A3A" }, // back to night
];

function skyAt(hour) {
  let a = SKY_KEYS[0], b = SKY_KEYS[SKY_KEYS.length - 1];
  for (let i = 0; i < SKY_KEYS.length - 1; i++) {
    if (hour >= SKY_KEYS[i].h && hour <= SKY_KEYS[i + 1].h) { a = SKY_KEYS[i]; b = SKY_KEYS[i + 1]; break; }
  }
  const t = (hour - a.h) / (b.h - a.h || 1);
  return { top: mix(a.top, b.top, t), mid: mix(a.mid, b.mid, t), bot: mix(a.bot, b.bot, t) };
}

// Sun up ~6:30–18:30, moon otherwise. Returns position along an arc + glow.
function celestialAt(hour) {
  const sunUp = hour >= 6.3 && hour <= 18.7;
  if (sunUp) {
    const t = (hour - 6.3) / (18.7 - 6.3);      // 0 at rise, 1 at set
    return { body: "sun", t, altitude: Math.sin(t * Math.PI) };
  }
  // moon: night wraps midnight, map to 0–1 across 18.7→06.3
  const nightLen = 24 - 18.7 + 6.3;
  const nh = hour >= 18.7 ? hour - 18.7 : hour + (24 - 18.7);
  const t = nh / nightLen;
  return { body: "moon", t, altitude: Math.sin(t * Math.PI) };
}

function phaseMeta(hour) {
  if (hour >= 5 && hour < 11) return { key: "dawn", label: "Morning", Icon: Sunrise, accent: "#E5793A", text: "#2A1810" };
  if (hour >= 11 && hour < 17) return { key: "day", label: "Afternoon", Icon: Sun, accent: "#0B6E7A", text: "#0A2A2E" };
  if (hour >= 17 && hour < 20.5) return { key: "dusk", label: "Evening", Icon: Moon, accent: "#B85C8A", text: "#2A1226" };
  return { key: "night", label: "Night", Icon: Moon, accent: "#8EA2FF", text: "#EDEBFF" };
}

function useTimePhase(overrideHour) {
  const [hour, setHour] = useState(overrideHour ?? liveHour());
  useEffect(() => {
    if (overrideHour != null) { setHour(overrideHour); return; }
    const id = setInterval(() => setHour(liveHour()), 30000);
    return () => clearInterval(id);
  }, [overrideHour]);
  const meta = phaseMeta(hour);
  return { ...meta, hour, sky: skyAt(hour), celestial: celestialAt(hour) };
}
function liveHour() { const d = new Date(); return d.getHours() + d.getMinutes() / 60; }
function fmtHour(h) { const hh = Math.floor(h); const mm = Math.round((h - hh) * 60); return `${String(hh).padStart(2,"0")}:${String(mm).padStart(2,"0")}`; }

const glass = (dark) => ({
  background: dark ? "rgba(255,255,255,0.08)" : "rgba(255,255,255,0.35)",
  backdropFilter: "blur(20px)",
  WebkitBackdropFilter: "blur(20px)",
  border: `1px solid ${dark ? "rgba(255,255,255,0.15)" : "rgba(255,255,255,0.55)"}`,
  boxShadow: "0 8px 32px rgba(0,0,0,0.12)",
});

const SCHEDULE = [
  { time: "07:30", title: "Morgenroutine", tag: "Persönlich", dur: "45 min", done: true },
  { time: "09:00", title: "Deep Work — Projekt", tag: "Fokus", dur: "2 Std", done: true },
  { time: "11:30", title: "German practice", tag: "Lernen", dur: "30 min", done: false, alarm: true },
  { time: "13:00", title: "Mittagspause", tag: "Pause", dur: "1 Std", done: false },
  { time: "15:00", title: "Team sync", tag: "Arbeit", dur: "45 min", done: false, alarm: true },
];

const USAGE = [
  { label: "Fokus", pct: 34, color: "#7B3FE4" },
  { label: "Arbeit", pct: 26, color: "#0B6E7A" },
  { label: "Lernen", pct: 18, color: "#E5793A" },
  { label: "Pause", pct: 14, color: "#2A9D8F" },
  { label: "Sonstiges", pct: 8, color: "#8EA2FF" },
];

export default function App() {
  const [tab, setTab] = useState("plan");
  const [demoHour, setDemoHour] = useState(null); // null = live
  const phase = useTimePhase(demoHour);
  const dark = phase.key === "night" || phase.key === "dusk";

  const { top, mid, bot } = phase.sky;
  const gradient = `linear-gradient(180deg, ${top} 0%, ${mid} 52%, ${bot} 100%)`;

  return (
    <div style={{ minHeight: "100vh", width: "100%", position: "relative", overflow: "hidden",
      fontFamily: "'DM Sans', system-ui, sans-serif", color: phase.text,
      background: gradient, transition: "background 1s ease, color 0.8s ease" }}>

      <Sky phase={phase} />

      <div style={{ maxWidth: 440, margin: "0 auto", padding: "24px 18px 110px", position: "relative", zIndex: 2 }}>
        <Header phase={phase} demoHour={demoHour} setDemoHour={setDemoHour} />

        {tab === "plan" && <PlanView phase={phase} dark={dark} />}
        {tab === "summary" && <SummaryView phase={phase} dark={dark} />}
        {tab === "chat" && <ChatView phase={phase} dark={dark} />}
      </div>

      <NavBar tab={tab} setTab={setTab} phase={phase} dark={dark} />

      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;700&family=Fraunces:opsz,wght@9..144,400;9..144,600&display=swap');
        @keyframes ringGrow { from { stroke-dashoffset: var(--circ); } }
        @keyframes slideUp { from { opacity:0; transform: translateY(14px);} to {opacity:1; transform:none;} }
        @keyframes pulse { 0%,100%{opacity:.4;transform:scale(1)} 50%{opacity:1;transform:scale(1.25)} }
        @keyframes drift { from { transform: translateX(-140px);} to { transform: translateX(calc(100vw + 140px)); } }
        @keyframes twinkle { 0%,100%{opacity:.25} 50%{opacity:1} }
        @keyframes sunPulse { 0%,100%{filter:blur(0) brightness(1)} 50%{filter:blur(.3px) brightness(1.08)} }
        * { box-sizing: border-box; }
        @media (prefers-reduced-motion: reduce){ *{animation:none!important;transition:none!important} }
      `}</style>
    </div>
  );
}

// Deterministic pseudo-random so stars/clouds don't jump every render.
const seeded = (n) => { const x = Math.sin(n * 999.7) * 43758.5; return x - Math.floor(x); };

function Sky({ phase }) {
  const { celestial, key, hour } = phase;
  const { body, t, altitude } = celestial;

  // Arc path: x goes left→right across the sky, y dips based on altitude.
  const x = 8 + t * 84;                  // % across
  const y = 78 - altitude * 60;          // % from top (higher altitude = smaller y)

  const isDayish = body === "sun";
  const starOpacity = key === "night" ? 1 : key === "dusk" ? 0.5 : 0;
  const cloudOpacity = key === "night" ? 0.12 : 0.9;
  const cloudTint = key === "dusk" ? "#e9b98f" : key === "night" ? "#20264a" : "#ffffff";

  return (
    <div aria-hidden style={{ position: "absolute", inset: 0, zIndex: 1, overflow: "hidden", pointerEvents: "none" }}>
      {/* Stars — only meaningful at night/dusk */}
      {starOpacity > 0 && (
        <div style={{ position: "absolute", inset: 0, opacity: starOpacity, transition: "opacity 1s ease" }}>
          {Array.from({ length: 46 }).map((_, i) => {
            const sx = seeded(i + 1) * 100, sy = seeded(i + 7) * 55, sz = 1 + seeded(i + 3) * 1.8;
            return <span key={i} style={{ position: "absolute", left: `${sx}%`, top: `${sy}%`,
              width: sz, height: sz, borderRadius: "50%", background: "#fff",
              boxShadow: "0 0 4px #fff", animation: `twinkle ${2.5 + seeded(i) * 3}s ${seeded(i+2)*3}s ease-in-out infinite` }} />;
          })}
        </div>
      )}

      {/* Sun glow halo */}
      {isDayish && altitude > 0.02 && (
        <div style={{ position: "absolute", left: `${x}%`, top: `${y}%`, transform: "translate(-50%,-50%)",
          width: 260, height: 260, borderRadius: "50%",
          background: `radial-gradient(circle, ${mix("#FFF6D8", "#FFC24B", 0.4)}88 0%, transparent 62%)`,
          transition: "all 1s ease" }} />
      )}

      {/* The sun or moon itself */}
      <div style={{ position: "absolute", left: `${x}%`, top: `${y}%`, transform: "translate(-50%,-50%)",
        transition: "all 1s ease", opacity: altitude < -0.05 ? 0 : 1 }}>
        {isDayish ? (
          <div style={{ width: 62, height: 62, borderRadius: "50%",
            background: `radial-gradient(circle at 38% 34%, #FFF7DE, #FFD34E 60%, #FBB03B)`,
            boxShadow: "0 0 40px 12px rgba(255,200,70,0.55)", animation: "sunPulse 6s ease-in-out infinite" }} />
        ) : (
          <div style={{ position: "relative", width: 54, height: 54, borderRadius: "50%",
            background: `radial-gradient(circle at 36% 32%, #FDFCF5, #DDE3F0 62%, #AEB6CE)`,
            boxShadow: "0 0 28px 6px rgba(220,228,255,0.4)", overflow: "hidden" }}>
            {/* craters */}
            {[[16,14,9],[32,30,7],[20,36,5]].map(([cx,cy,r],i)=>(
              <span key={i} style={{ position:"absolute", left:cx, top:cy, width:r, height:r,
                borderRadius:"50%", background:"rgba(150,160,190,0.45)" }} />
            ))}
          </div>
        )}
      </div>

      {/* Drifting clouds — denser by day, faint wisps at night */}
      {[
        { top: "12%", scale: 1.1, dur: 60, delay: 0 },
        { top: "24%", scale: 0.75, dur: 85, delay: -30 },
        { top: "18%", scale: 0.9, dur: 72, delay: -55 },
      ].map((c, i) => (
        <div key={i} style={{ position: "absolute", top: c.top, left: 0,
          opacity: cloudOpacity, transition: "opacity 1s ease",
          transform: `scale(${c.scale})`, animation: `drift ${c.dur}s linear ${c.delay}s infinite` }}>
          <Cloud tint={cloudTint} />
        </div>
      ))}
    </div>
  );
}

function Cloud({ tint }) {
  return (
    <svg width="150" height="60" viewBox="0 0 150 60" style={{ filter: "blur(1px)" }}>
      <g fill={tint} opacity="0.92">
        <ellipse cx="45" cy="38" rx="34" ry="18" />
        <ellipse cx="72" cy="30" rx="28" ry="20" />
        <ellipse cx="98" cy="38" rx="30" ry="16" />
        <rect x="30" y="38" width="90" height="16" rx="8" />
      </g>
    </svg>
  );
}

function Header({ phase, demoHour, setDemoHour }) {
  const { Icon } = phase;
  return (
    <div style={{ animation: "slideUp .5s ease both" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
        <Icon size={18} strokeWidth={2.2} />
        <span style={{ fontSize: 13, letterSpacing: 2, textTransform: "uppercase", fontWeight: 500, opacity: .85 }}>
          {phase.label} · {demoHour == null ? "live" : fmtHour(demoHour)}
        </span>
      </div>
      <h1 style={{ fontFamily: "'Fraunces', serif", fontWeight: 600, fontSize: 34, margin: "2px 0 14px", lineHeight: 1.05 }}>
        Guten Tag.
      </h1>

      {/* time-of-day scrubber so you can *see* the sky react */}
      <div style={{ ...glass(phase.key === "night" || phase.key === "dusk"), borderRadius: 16, padding: "10px 14px", marginBottom: 22 }}>
        <div style={{ fontSize: 11, opacity: .8, marginBottom: 6, fontWeight: 500 }}>
          Drag to move the sun & moon → try 6:30 and 18:30
        </div>
        <input type="range" min={0} max={23.5} step={0.5} value={demoHour ?? phase.hour}
          onChange={(e) => setDemoHour(Number(e.target.value))}
          style={{ width: "100%", accentColor: phase.accent }} />
      </div>
    </div>
  );
}

function PlanView({ phase, dark }) {
  const [items, setItems] = useState(SCHEDULE);
  const toggle = (i) => setItems(items.map((it, idx) => idx === i ? { ...it, done: !it.done } : it));

  return (
    <div>
      <SectionTitle phase={phase}>Heute</SectionTitle>
      {items.map((it, i) => (
        <div key={i} style={{ ...glass(dark), borderRadius: 20, padding: 16, marginBottom: 12,
          display: "flex", alignItems: "center", gap: 14,
          animation: `slideUp .5s ease ${i * 0.07}s both` }}>
          <div style={{ minWidth: 52, textAlign: "center" }}>
            <div style={{ fontFamily: "'Fraunces',serif", fontSize: 17, fontWeight: 600 }}>{it.time.split(":")[0]}</div>
            <div style={{ fontSize: 11, opacity: .7 }}>:{it.time.split(":")[1]}</div>
          </div>
          <div style={{ width: 3, alignSelf: "stretch", borderRadius: 3, background: phase.accent, opacity: it.done ? .3 : .9 }} />
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 15.5, fontWeight: 600, textDecoration: it.done ? "line-through" : "none", opacity: it.done ? .55 : 1 }}>
              {it.title}
            </div>
            <div style={{ display: "flex", gap: 8, alignItems: "center", marginTop: 3 }}>
              <span style={{ fontSize: 11, padding: "2px 8px", borderRadius: 20, background: phase.accent + "22", color: phase.accent, fontWeight: 600 }}>{it.tag}</span>
              <span style={{ fontSize: 11, opacity: .7 }}>{it.dur}</span>
              {it.alarm && <Bell size={12} style={{ opacity: .8 }} />}
            </div>
          </div>
          <button onClick={() => toggle(i)} aria-label="toggle done"
            style={{ width: 30, height: 30, borderRadius: "50%", cursor: "pointer",
              border: `2px solid ${it.done ? phase.accent : "rgba(0,0,0,0.15)"}`,
              background: it.done ? phase.accent : "transparent",
              display: "flex", alignItems: "center", justifyContent: "center", transition: "all .25s" }}>
            {it.done && <Check size={16} color="#fff" strokeWidth={3} />}
          </button>
        </div>
      ))}

      <button style={{ ...glass(dark), width: "100%", borderRadius: 20, padding: 16, marginTop: 4,
        display: "flex", alignItems: "center", justifyContent: "center", gap: 8, cursor: "pointer",
        color: phase.text, fontSize: 15, fontWeight: 600, fontFamily: "inherit" }}>
        <Plus size={18} /> Add block
      </button>
    </div>
  );
}

function SummaryView({ phase, dark }) {
  return (
    <div>
      <div style={{ ...glass(dark), borderRadius: 24, padding: 24, marginBottom: 18, textAlign: "center",
        animation: "slideUp .5s ease both" }}>
        <div style={{ display: "inline-flex", alignItems: "center", gap: 6, fontSize: 12, letterSpacing: 1.5,
          textTransform: "uppercase", opacity: .85, marginBottom: 14, fontWeight: 600 }}>
          <Sparkles size={14} /> Your week, wrapped
        </div>
        <Rings phase={phase} />
        <div style={{ fontFamily: "'Fraunces',serif", fontSize: 30, fontWeight: 600, marginTop: 12 }}>28.5 Std</div>
        <div style={{ fontSize: 13, opacity: .75 }}>tracked · 12% more focus than last week</div>
      </div>

      <SectionTitle phase={phase}>Where it went</SectionTitle>
      <div style={{ ...glass(dark), borderRadius: 20, padding: 18 }}>
        {USAGE.map((u, i) => (
          <div key={u.label} style={{ marginBottom: i === USAGE.length - 1 ? 0 : 14, animation: `slideUp .5s ease ${i*0.08}s both` }}>
            <div style={{ display: "flex", justifyContent: "space-between", fontSize: 13, marginBottom: 5, fontWeight: 500 }}>
              <span>{u.label}</span><span style={{ opacity: .7 }}>{u.pct}%</span>
            </div>
            <div style={{ height: 8, borderRadius: 8, background: "rgba(0,0,0,0.1)", overflow: "hidden" }}>
              <div style={{ height: "100%", width: `${u.pct}%`, background: u.color, borderRadius: 8,
                transition: "width 1s ease" }} />
            </div>
          </div>
        ))}
      </div>

      <div style={{ ...glass(dark), borderRadius: 20, padding: 18, marginTop: 14, display: "flex", gap: 12, alignItems: "center" }}>
        <div style={{ fontSize: 30 }}>🔥</div>
        <div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>6-day streak</div>
          <div style={{ fontSize: 12.5, opacity: .75 }}>Your most consistent morning was Tuesday.</div>
        </div>
      </div>
    </div>
  );
}

function Rings({ phase }) {
  const rings = [
    { r: 62, pct: 78, color: phase.accent },
    { r: 48, pct: 60, color: "#2A9D8F" },
    { r: 34, pct: 42, color: "#E5793A" },
  ];
  return (
    <svg width="170" height="170" viewBox="0 0 170 170" style={{ display: "block", margin: "0 auto" }}>
      {rings.map((ring, i) => {
        const circ = 2 * Math.PI * ring.r;
        return (
          <g key={i} transform="rotate(-90 85 85)">
            <circle cx="85" cy="85" r={ring.r} fill="none" stroke="rgba(0,0,0,0.1)" strokeWidth="10" />
            <circle cx="85" cy="85" r={ring.r} fill="none" stroke={ring.color} strokeWidth="10" strokeLinecap="round"
              strokeDasharray={circ} strokeDashoffset={circ * (1 - ring.pct / 100)}
              style={{ "--circ": circ, animation: `ringGrow 1.2s ease ${i * 0.15}s both` }} />
          </g>
        );
      })}
    </svg>
  );
}

function ChatView({ phase, dark }) {
  const [msgs, setMsgs] = useState([
    { from: "bot", text: "Hallo! Ich bin dein Deutsch-Assistent. Ganz offline. Wie kann ich helfen?" },
    { from: "user", text: "Wie sage ich 'I need to reschedule'?" },
    { from: "bot", text: "„Ich muss den Termin verschieben.“ — Das ist höflich und klar. Möchtest du ein Beispiel?" },
  ]);
  const [val, setVal] = useState("");
  const [typing, setTyping] = useState(false);
  const endRef = useRef();
  useEffect(() => { endRef.current?.scrollIntoView({ behavior: "smooth" }); }, [msgs, typing]);

  const send = () => {
    if (!val.trim()) return;
    setMsgs(m => [...m, { from: "user", text: val }]);
    setVal("");
    setTyping(true);
    setTimeout(() => { setTyping(false); setMsgs(m => [...m, { from: "bot", text: "Gute Frage! Hier ist eine natürliche Formulierung…" }]); }, 1300);
  };

  return (
    <div>
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 14 }}>
        <SectionTitle phase={phase} inline>Assistent</SectionTitle>
        <span style={{ fontSize: 11, padding: "3px 9px", borderRadius: 20, background: "#2A9D8F22", color: "#2A9D8F", fontWeight: 700, display: "inline-flex", alignItems: "center", gap: 5 }}>
          <span style={{ width: 6, height: 6, borderRadius: "50%", background: "#2A9D8F", animation: "pulse 2s infinite" }} /> Offline
        </span>
      </div>

      <div style={{ minHeight: 300 }}>
        {msgs.map((m, i) => (
          <div key={i} style={{ display: "flex", justifyContent: m.from === "user" ? "flex-end" : "flex-start", marginBottom: 10,
            animation: "slideUp .4s ease both" }}>
            <div style={{ maxWidth: "80%", padding: "11px 15px", borderRadius: 18, fontSize: 14.5, lineHeight: 1.45,
              ...(m.from === "user"
                ? { background: phase.accent, color: "#fff", borderBottomRightRadius: 5 }
                : { ...glass(dark), borderBottomLeftRadius: 5 }) }}>
              {m.text}
            </div>
          </div>
        ))}
        {typing && (
          <div style={{ display: "flex", gap: 4, padding: "12px 16px", ...glass(dark), borderRadius: 18, width: "fit-content" }}>
            {[0,1,2].map(d => <span key={d} style={{ width: 7, height: 7, borderRadius: "50%", background: phase.accent, animation: `pulse 1s ${d*0.2}s infinite` }} />)}
          </div>
        )}
        <div ref={endRef} />
      </div>

      <div style={{ ...glass(dark), borderRadius: 24, padding: 6, display: "flex", gap: 6, alignItems: "center", marginTop: 10 }}>
        <input value={val} onChange={e => setVal(e.target.value)} onKeyDown={e => e.key === "Enter" && send()}
          placeholder="Auf Deutsch schreiben…"
          style={{ flex: 1, border: "none", background: "transparent", outline: "none", padding: "10px 14px", fontSize: 14.5, color: phase.text, fontFamily: "inherit" }} />
        <button onClick={send} aria-label="send" style={{ width: 42, height: 42, borderRadius: "50%", border: "none", cursor: "pointer",
          background: phase.accent, display: "flex", alignItems: "center", justifyContent: "center" }}>
          <Send size={18} color="#fff" />
        </button>
      </div>
    </div>
  );
}

function SectionTitle({ children, phase, inline }) {
  return <h2 style={{ fontFamily: "'Fraunces',serif", fontWeight: 600, fontSize: 20, margin: inline ? 0 : "0 0 12px" }}>{children}</h2>;
}

function NavBar({ tab, setTab, phase, dark }) {
  const items = [
    { id: "plan", Icon: Clock, label: "Plan" },
    { id: "summary", Icon: BarChart3, label: "Summary" },
    { id: "chat", Icon: MessageCircle, label: "Assistent" },
  ];
  return (
    <div style={{ position: "fixed", bottom: 16, left: "50%", transform: "translateX(-50%)", zIndex: 10,
      display: "flex", gap: 4, padding: 6, borderRadius: 28, ...glass(dark) }}>
      {items.map(({ id, Icon, label }) => {
        const active = tab === id;
        return (
          <button key={id} onClick={() => setTab(id)}
            style={{ display: "flex", alignItems: "center", gap: 7, padding: "10px 16px", borderRadius: 22, cursor: "pointer",
              border: "none", fontFamily: "inherit", fontSize: 13.5, fontWeight: 600, transition: "all .3s",
              background: active ? phase.accent : "transparent", color: active ? "#fff" : phase.text }}>
            <Icon size={18} strokeWidth={2.2} />
            {active && <span>{label}</span>}
          </button>
        );
      })}
    </div>
  );
}
