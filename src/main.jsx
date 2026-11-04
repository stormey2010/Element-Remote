import {
  isNativeIOS,
  loadConnectionConfig,
  saveConnectionConfig,
  selectionHaptic,
  loadPreferences,
  savePreferences,
} from "./platform";
import React, { useState, useEffect, useCallback, lazy, Suspense } from "react";
import { createRoot } from "react-dom/client";
import {
  connect,
  useMessage,
  useMessages,
  useStatus,
  send,
  coalesce,
  key,
  tap,
  command,
  subscribeNotice,
  readMessage,
} from "./osc";
import "./style.css";
const ExtraViews = lazy(() => import("./views.jsx"));
const tabs = [
  ["console", "▦", "Console"],
  ["faders", "☷", "Faders"],
  ["wheels", "↗", "Wheels"],
  ["color", "◉", "Color"],
  ["patch", "⋈", "Patch"],
  ["cues", "≡", "Cues"],
  ["focus", "◎", "Focus"],
  ["playback", "▷", "Playback"],
  ["subs", "☷", "Subs"],
  ["macros", "⌘", "Macros"],
  ["connect", "⚙", "Connect"],
  ["more", "···", "More"],
];
function Icon({ name, size = 22 }) {
  const paths = {
    console: "M4 4h16v16H4z M4 10h16 M10 4v16",
    faders: "M5 3v18 M12 3v18 M19 3v18 M2 8h6 M9 15h6 M16 7h6",
    wheels: "M5 19V5 M5 19h14 M10 14l9-9 M14 5h5v5",
    color:
      "M12 3a9 9 0 1 0 9 9c0-2-2-2-3-2h-2a2 2 0 0 1-2-2c0-1 1-2 1-3s-1-2-3-2 M7 10h.01 M8 15h.01 M11 7h.01",
    patch: "M4 5h4v4H4z M16 15h4v4h-4z M8 7h4v10h4 M4 17h4 M16 7h4",
    cues: "M8 5h12 M8 12h12 M8 19h12 M4 5h.01 M4 12h.01 M4 19h.01",
    focus: "M8 3H3v5 M16 3h5v5 M21 16v5h-5 M8 21H3v-5 M8 12h8 M12 8v8",
    playback: "M8 5l11 7-11 7z",
    subs: "M4 7h16 M4 12h16 M4 17h16 M8 4v6 M16 9v6 M10 14v6",
    macros: "M13 2L4 14h7l-1 8 10-12h-7z",
    connect:
      "M9 3h6l1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1z M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0",
    more: "M5 12h.01 M12 12h.01 M19 12h.01",
    live: "M12 8v4 M12 16h.01 M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0",
  };
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={paths[name] || paths.console} />
    </svg>
  );
}
function readTab() {
  const hash = location.hash.slice(1);
  return hash === "directs"
    ? "faders"
    : tabs.some((t) => t[0] === hash)
      ? hash
      : "console";
}
export function Button({ children, onClick, ...props }) {
  return (
    <button
      type="button"
      onClick={
        onClick
          ? (event) => {
              selectionHaptic();
              onClick(event);
            }
          : undefined
      }
      {...props}
    >
      {children}
    </button>
  );
}
export function Title({ children, aside }) {
  return (
    <div className="view-title">
      <h2>{children}</h2>
      {aside}
    </div>
  );
}
export function Panel({ children, className = "" }) {
  return <div className={"panel " + className}>{children}</div>;
}
export function useLostConnection(fn) {
  const status = useStatus();
  useEffect(() => {
    if (!status.bridge) fn();
  }, [status.bridge]);
}
function App() {
  const [tab, setTab] = useState(readTab),
    [toast, setToast] = useState("");
  const status = useStatus(),
    show = useMessage("/eos/out/show/name"),
    cmd = useMessage("/eos/out/cmd");
  useEffect(() => {
    const f = () => setTab(readTab());
    window.addEventListener("hashchange", f);
    return () => window.removeEventListener("hashchange", f);
  }, []);
  useEffect(() => subscribeNotice(setToast), []);
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(""), 3500);
    return () => clearTimeout(t);
  }, [toast]);
  return (
    <div className="app">
      <header>
        <Button aria-label="Live" className="icon" onClick={() => key("live")}>
          <Icon name="live" />
        </Button>

        <span className="wordmark">
          Element <small>Remote</small>
        </span>
        <a href="#connect" className="connection">
          <i className={status.consoleOnline ? "dot online" : "dot"} />
          {status.consoleOnline
            ? "Console connected"
            : status.bridge
              ? "Console setup"
              : "Reconnecting…"}{" "}
          <Icon name="connect" size={18} />
        </a>
      </header>
      <div className="show-bar">
        <span>
          <i className={status.consoleOnline ? "dot online" : "dot"} />
          {status.consoleOnline
            ? "Console responding"
            : status.configured
              ? "Awaiting console"
              : "Console not configured"}
        </span>
        <span>{show[0] || "No show feedback"}</span>
      </div>
      <main data-view={tab}>
        {isNativeIOS && !status.configured && tab !== "connect" && (
          <div className="native-welcome">
            <span className="welcome-icon">
              <Icon name="connect" size={26} />
            </span>
            <div>
              <h3>Connect to Element</h3>
              <p>
                Join the console’s Wi-Fi, then add its IP address. No server
                needed.
              </p>
              <a href="#connect">
                Set up connection <span>→</span>
              </a>
            </div>
          </div>
        )}
          <div
            className={
              "command-display " + (status.consoleOnline ? "online" : "")
            }
          >
            <output>
              {cmd[0] ||
                (status.consoleOnline
                  ? "Ready"
                  : status.bridge
                    ? "Waiting for console…"
                    : "Disconnected")}
            </output>
            <a href="#connect" aria-label="Connection settings">
              <Icon name="connect" size={18} />
            </a>
          </div>
        <Suspense
          fallback={
            <Panel>
              <p>Loading controls…</p>
            </Panel>
          }
        >
          {tab === "more" ? (
            <>
              <Title>More controls</Title>
              {isNativeIOS && <MobilePreferences />}
              <div className="tools-grid">
                {tabs
                  .filter(
                    ([id]) =>
                      !["console", "faders", "playback", "more"].includes(id),
                  )
                  .map(([id, icon, label]) => (
                    <a key={id} href={"#" + id}>
                      <span className="tool-icon">
                        <Icon name={id} size={25} />
                      </span>
                      <span>{label}</span>
                      <small>
                        {
                          {
                            wheels: "Pan, tilt and fixture parameters",
                            color: "Color picker and palettes",
                            patch: "Fixture addresses and types",
                            cues: "Cue list and playback",
                            focus: "Channel selection and intensity",
                            subs: "Submaster levels and bumps",
                            macros: "Run console shortcuts",
                            connect: "Console and network settings",
                          }[id]
                        }
                      </small>
                    </a>
                  ))}
              </div>
              <Panel>
                <h3>How control works</h3>
                <p className="hint">
                  {isNativeIOS
                    ? "This app sends OSC directly from your device to Element over Wi-Fi. No server is required. Connect both to the console’s local network."
                    : "This website sends commands through the computer running its bridge. That computer must be able to reach Element. A phone browser alone cannot send raw OSC directly to the console."}
                </p>
              </Panel>
            </>
          ) : tab === "console" ? (
            <Console />
          ) : tab === "faders" ? (
            <Faders />
          ) : tab === "focus" ? (
            <Focus />
          ) : tab === "playback" ? (
            <Playback />
          ) : tab === "subs" ? (
            <Submasters />
          ) : tab === "macros" ? (
            <Macros />
          ) : tab === "connect" ? (
            <Connection />
          ) : (
            <ExtraViews tab={tab} />
          )}
        </Suspense>
      </main>
      <nav aria-label="Workspace">
        {tabs
          .filter(([id]) =>
            ["console", "faders", "playback", "more"].includes(id),
          )
          .map(([id, icon, label]) => (
            <a
              key={id}
              href={"#" + id}
              aria-current={
                id === tab ||
                (id === "more" &&
                  !["console", "faders", "playback"].includes(tab))
                  ? "page"
                  : undefined
              }
              className={
                id === tab ||
                (id === "more" &&
                  !["console", "faders", "playback"].includes(tab))
                  ? "active"
                  : ""
              }
            >
              <span className="nav-icon">
                <Icon name={id} />
              </span>
              <span>{label}</span>
            </a>
          ))}
      </nav>
      {toast && (
        <div className="toast" role="status">
          {toast}
        </div>
      )}
    </div>
  );
}
const keypad = [
  ["Record", "record", "record-key"],
  null,
  null,
  ["/", "\\"],
  ["High", "highlight"],
  ["Sneak", "sneak"],
  ["Cue", "cue", "cue-key"],
  ["+", "+"],
  ["Thru", "thru"],
  ["−", "-"],
  ["Delay", "delay"],
  ["Time", "time"],
  ["Sub", "sub", "sub-key"],
  ["7", "7", "number"],
  ["8", "8", "number"],
  ["9", "9", "number"],
  ["Rem Dim", "rem_dim"],
  ["Home", "home"],
  ["Go To Cue", "go_to_cue", "goto-key"],
  ["4", "4", "number"],
  ["5", "5", "number"],
  ["6", "6", "number"],
  ["Out", "out"],
  ["Level", "level"],
  ["Chan", "chan", "chan-key"],
  ["1", "1", "number"],
  ["2", "2", "number"],
  ["3", "3", "number"],
  ["At", "@"],
  ["Full", "full"],
  ["Group", "group", "group"],
  ["Clear", "clear_cmd"],
  ["0", "0", "number"],
  [".", "."],
  ["Enter", "enter", "enter"],
];
function Console() {
  return (
    <>
      <Panel>
        <div className="six-grid categories">
          {["Intensity", "Focus", "Color", "Shutter", "Image", "Form"].map(
            (k) => (
              <Button key={k} onClick={() => key(k.toLowerCase().replaceAll(" ", "_"))}>
                {k}
              </Button>
            ),
          )}
        </div>
        <div className="six-grid">
          {[
            ["Macro", "macro"],
            ["Effect", "effect"],
            ["Recall From", "recall_from"],
            ["Park", "park"],
            ["Select Last", "select_last"],
            ["Select Man", "select_manual"],
            ["Last", "last"],
            ["Next", "next"],
          ].map(([l, k]) => (
            <Button key={k} onClick={() => key(k)}>
              {l}
            </Button>
          ))}
        </div>
      </Panel>
      <Panel>
        <div className="six-grid keypad">
          {keypad.map((k, i) =>
            k ? (
              <Button key={i} className={k[2] || ""} onClick={() => key(k[1])}>
                {k[0]}
              </Button>
            ) : (
              <span key={i} />
            ),
          )}
        </div>
      </Panel>
      <Panel>
        <h3>More console keys</h3>
        <div className="three-grid">
          {["Update", "Delete", "Label", "Copy To", "Move To", "Block", "Assert", "Undo", "About", "Live", "Blind", "Escape"].map((k) => (
            <Button key={k} onClick={() => key(k.toLowerCase().replaceAll(" ", "_"))}>
              {k}
            </Button>
          ))}
        </div>
      </Panel>
    </>
  );
}
const FaderTile = React.memo(function FaderTile({
  number,
  selected,
  onToggle,
}) {
  const name = useMessage(`/eos/out/fader/1/${number}/name`),
    a = useMessage(`/eos/fader/1/${number}`),
    b = useMessage(`/eos/out/fader/1/${number}`);
  const level = (a.length ? a : b)[0];
  return (
    <Button
      className={"fader-tile " + (selected ? "selected" : "")}
      aria-label={`Select fader ${number}`}
      aria-pressed={selected}
      onClick={() => onToggle(number)}
    >
      <span className="fader-number">{String(number).padStart(2, "0")}</span>
      <span className="fader-label">{name[0] || "Fader " + number}</span>
      <span className="fader-readout">
        {typeof level === "number" ? Math.round(level * 100) + "%" : "—"}
      </span>
    </Button>
  );
});
function Faders() {
  const [selected, setSelected] = useState([]),
    [level, setLevel] = useState(0),
    [last, setLast] = useState("");
  const status = useStatus();
  const feedback = useMessages(
    selected.flatMap((n) => [`/eos/fader/1/${n}`, `/eos/out/fader/1/${n}`]),
  );
  const values = selected.map(
    (_, i) =>
      (feedback[i * 2].length ? feedback[i * 2] : feedback[i * 2 + 1])[0],
  );
  const common =
    values.length && values.every((v) => typeof v === "number")
      ? values.every((v) => v === values[0])
        ? Math.round(values[0] * 100) + "%"
        : "Mixed"
      : "—";
  useEffect(() => {
    setSelected([]);
    setLast("");
  }, [status.bridge, status.session]);
  const toggle = useCallback((n) => {
    setSelected((prev) =>
      prev.includes(n) ? prev.filter((v) => v !== n) : [...prev, n],
    );
    setLast("");
  }, []);
  const selectionKey = selected.join(",");
  useEffect(() => {
    const n = selected[0];
    if (!n) return;
    const a = readMessage(`/eos/fader/1/${n}`),
      b = readMessage(`/eos/out/fader/1/${n}`),
      value = (a.length ? a : b)[0];
    if (typeof value === "number") setLevel(Math.round(value * 100));
  }, [selectionKey]);
  function apply(value) {
    let sent = false;
    selected.forEach((n) => {
      if (coalesce(`/eos/fader/1/${n}`, [value / 100])) sent = true;
    });
    if (sent) {
      setLevel(value);
      setLast("Last sent " + value + "%");
    }
  }
  return (
    <>
      <Title aside={<small>{selected.length} selected</small>}>Faders</Title>
      <div className="fader-workspace">
        <div className="all-faders" aria-label="40 faders">
          {Array.from({ length: 40 }, (_, i) => (
            <FaderTile
              key={i}
              number={i + 1}
              selected={selected.includes(i + 1)}
              onToggle={toggle}
            />
          ))}
        </div>
        <aside className="fader-controls panel">
          <h3>Selected faders</h3>
          <p className="selection-summary">
            {selected.length
              ? selected
                  .slice()
                  .sort((a, b) => a - b)
                  .join(", ")
              : "Tap faders to select"}
          </p>
          <div className="select-actions">
            <Button
              onClick={() => {
                setSelected(Array.from({ length: 40 }, (_, i) => i + 1));
                setLast("");
              }}
            >
              All
            </Button>
            <Button
              onClick={() => {
                setSelected([]);
                setLast("");
              }}
            >
              Clear
            </Button>
          </div>
          <label htmlFor="group-level">Set level</label>
          <output className="big-level">{last ? level + "%" : common}</output>
          <input
            id="group-level"
            aria-label="Selected faders level"
            type="range"
            min="0"
            max="100"
            value={level}
            disabled={!selected.length}
            onChange={(e) => apply(Number(e.target.value))}
          />
          <small>
            {last ||
              (selected.length
                ? "Console levels · " + common
                : "Selection does not change levels")}
          </small>
          <div className="side-presets">
            {[0, 25, 50, 75, 100].map((n) => (
              <Button
                key={n}
                disabled={!selected.length}
                onClick={() => apply(n)}
              >
                {n === 0 ? "Out" : n === 100 ? "Full" : n + "%"}
              </Button>
            ))}
          </div>
          <p className="hint">
            Level controls set every selected fader to the same value.
          </p>
        </aside>
      </div>
    </>
  );
}
function Focus() {
  const [channel, setChannel] = useState(1);
  const selection = useMessage("/eos/out/active/chan"),
    [level, setLevel] = useState(0);
  return (
    <>
      <Title>Channel focus</Title>
      <Panel>
        <form
          className="inline-form"
          onSubmit={(e) => {
            e.preventDefault();
            send("/eos/chan", [Number(channel)]);
          }}
        >
          <label>
            Channel
            <input
              type="number"
              min="1"
              max="99999"
              required
              value={channel}
              onChange={(e) => setChannel(e.target.value)}
            />
          </label>
          <button>Select channel</button>
        </form>
        <p className="feedback">
          Console selection <b>{selection[0] || "—"}</b>
        </p>
        <label>
          Selected intensity <output>{level}%</output>
          <input
            aria-label="Selected intensity"
            type="range"
            min="0"
            max="100"
            value={level}
            onChange={(e) => {
              const n = Number(e.target.value);
              if (coalesce("/eos/at", [n])) setLevel(n);
            }}
          />
        </label>
        <div className="five-grid">
          {[0, 25, 50, 75, 100].map((n) => (
            <Button
              key={n}
              onClick={() => {
                if (send("/eos/at", [n])) setLevel(n);
              }}
            >
              {n === 0 ? "Out" : n === 100 ? "Full" : n + "%"}
            </Button>
          ))}
        </div>
        <div className="three-grid">
          {[
            ["Last", "last"],
            ["Next", "next"],
            ["Rem Dim", "rem_dim"],
          ].map(([l, k]) => (
            <Button key={k} onClick={() => key(k)}>
              {l}
            </Button>
          ))}
        </div>
        <p className="hint">Slider shows your last sent level.</p>
      </Panel>
    </>
  );
}
function Playback() {
  const active = useMessage("/eos/out/active/cue/text"),
    pending = useMessage("/eos/out/pending/cue/text"),
    [cue, setCue] = useState("");
  return (
    <>
      <Title>Playback</Title>
      <Panel>
        <small>ACTIVE CUE</small>
        <h2>{active[0] || "No cue feedback"}</h2>
        <p className="feedback">
          Pending <b>{pending[0] || "—"}</b>
        </p>
        <div className="two-grid playback-buttons">
          <Button onClick={() => key("stop")}>Ⅱ Stop / Back</Button>
          <Button className="accent" onClick={() => key("go_0")}>
            ▶ Go
          </Button>
        </div>
        <form
          className="inline-form"
          onSubmit={(e) => {
            e.preventDefault();
            command(`Go_To_Cue ${Number(cue)} Enter`);
          }}
        >
          <label>
            Cue number
            <input
              type="number"
              min="0"
              step="0.001"
              value={cue}
              onChange={(e) => setCue(e.target.value)}
              required
            />
          </label>
          <button>Go to cue</button>
        </form>
      </Panel>
    </>
  );
}
function Bump({ address, label }) {
  const release = () => {
    if (held.current) {
      send(address, [0]);
      held.current = false;
    }
  };
  const held = React.useRef(false);
  useEffect(() => {
    window.addEventListener("blur", release);
    window.addEventListener("pagehide", release);
    const hide = () => {
      if (document.hidden) release();
    };
    document.addEventListener("visibilitychange", hide);
    return () => {
      release();
      window.removeEventListener("blur", release);
      window.removeEventListener("pagehide", release);
      document.removeEventListener("visibilitychange", hide);
    };
  }, [address]);
  return (
    <Button
      aria-label={label}
      className="bump"
      onPointerDown={(e) => {
        if (e.button !== 0) return;
        e.preventDefault();
        if (send(address, [1])) {
          held.current = true;
          e.currentTarget.setPointerCapture(e.pointerId);
        }
      }}
      onPointerUp={release}
      onPointerCancel={release}
      onLostPointerCapture={release}
      onKeyDown={(e) => {
        if ([" ", "Enter"].includes(e.key) && !e.repeat) {
          e.preventDefault();
          if (send(address, [1])) held.current = true;
        }
      }}
      onKeyUp={(e) => {
        if ([" ", "Enter"].includes(e.key)) {
          e.preventDefault();
          release();
        }
      }}
      onBlur={release}
    >
      Bump
    </Button>
  );
}
function Sub({ n }) {
  const [level, setLevel] = useState(null);
  return (
    <Panel>
      <h3>Sub {n}</h3>
      <output className="big-level">
        {level === null ? "—" : level + "%"}
      </output>
      <input
        type="range"
        min="0"
        max="100"
        aria-label={`Submaster ${n} level`}
        value={level ?? 0}
        onChange={(e) => {
          const l = Number(e.target.value);
          if (coalesce(`/eos/sub/${n}`, [l / 100])) setLevel(l);
        }}
      />
      <small>Last sent</small>
      <Bump address={`/eos/sub/${n}/fire`} label={`Bump submaster ${n}`} />
    </Panel>
  );
}
function Submasters() {
  const [start, setStart] = useState(1);
  return (
    <>
      <Title
        aside={
          <select
            aria-label="Submaster bank"
            value={start}
            onChange={(e) => setStart(Number(e.target.value))}
          >
            {[1, 9, 17, 25, 33].map((n) => (
              <option value={n} key={n}>
                {n}–{n + 7}
              </option>
            ))}
          </select>
        }
      >
        Submasters
      </Title>
      <div className="sub-grid">
        {Array.from({ length: 8 }, (_, i) => (
          <Sub key={start + i} n={start + i} />
        ))}
      </div>
    </>
  );
}
function Macros() {
  const [n, setN] = useState(1);
  return (
    <>
      <Title>Macros</Title>
      <Panel>
        <form
          className="inline-form"
          onSubmit={(e) => {
            e.preventDefault();
            tap(`/eos/macro/${Number(n)}/fire`);
          }}
        >
          <label>
            Macro number
            <input
              type="number"
              min="1"
              max="99999"
              value={n}
              onChange={(e) => setN(e.target.value)}
              required
            />
          </label>
          <button>Run macro</button>
        </form>
      </Panel>
      <div className="macro-grid">
        {Array.from({ length: 12 }, (_, i) => (
          <Button key={i} onClick={() => tap(`/eos/macro/${i + 1}/fire`)}>
            <b>{String(i + 1).padStart(2, "0")}</b>Run macro
          </Button>
        ))}
      </div>
    </>
  );
}
function MobilePreferences() {
  const [preferences, setPreferences] = useState(loadPreferences);
  function update(key, value) {
    const next = { ...preferences, [key]: value };
    setPreferences(next);
    savePreferences(next);
  }
  return (
    <Panel className="mobile-preferences">
      <h3>On this device</h3>
      <label>
        Haptic feedback
        <input
          role="switch"
          type="checkbox"
          checked={preferences.haptics}
          onChange={(e) => update("haptics", e.target.checked)}
        />
      </label>
      <label>
        Keep screen awake
        <input
          role="switch"
          type="checkbox"
          checked={preferences.keepAwake}
          onChange={(e) => update("keepAwake", e.target.checked)}
        />
      </label>
    </Panel>
  );
}
function Connection() {
  const status = useStatus(),
    [form, setForm] = useState(null),
    [saving, setSaving] = useState(false),
    [error, setError] = useState(""),
    [saved, setSaved] = useState(false);
  useEffect(() => {
    loadConnectionConfig()
      .then(setForm)
      .catch((e) => setError(e.message));
  }, []);
  async function save(e) {
    e.preventDefault();
    setSaving(true);
    setError("");
    setSaved(false);
    try {
      const data = await saveConnectionConfig(form);
      setForm(data);
      setSaved(true);
    } catch (e) {
      setError(e.message);
    } finally {
      setSaving(false);
    }
  }
  return (
    <>
      <Title>Connections</Title>
      <Panel>
        <div className="connection-heading">
          <span className="connection-symbol">
            <Icon name="connect" size={23} />
          </span>
          <div>
            <h3>{form?.displayName || "Element"}</h3>
            <p>
              {status.consoleOnline
                ? "Console connected"
                : status.configured
                  ? "Waiting for console"
                  : "Add your console"}
            </p>
          </div>
          <i className={status.consoleOnline ? "dot online" : "dot"} />
        </div>
        <p className="hint">
          {isNativeIOS
            ? "Your iPhone or iPad connects directly to Element. Join the console’s Wi-Fi network, then enter its address."
            : "Save your console’s address and connection method. The bridge must be able to reach your console’s network."}
        </p>
        {form ? (
          <form className="connection-form" onSubmit={save}>
            <label>
              Display name
              <input
                value={form.displayName || ""}
                maxLength="64"
                onChange={(e) =>
                  setForm({ ...form, displayName: e.target.value })
                }
                placeholder="Tech"
              />
            </label>
            <label>
              Console IPv4 address
              <input
                inputMode="decimal"
                value={form.consoleHost}
                placeholder="e.g. 192.168.1.102"
                onChange={(e) =>
                  setForm({ ...form, consoleHost: e.target.value })
                }
              />
            </label>
            <div className="protocol-setting">
              <span>Connection mode</span>
              <div
                className="segmented"
                role="group"
                aria-label="Connection mode"
              >
                {[
                  ["udp", "UDP"],
                  ["tcp", "TCP"],
                  ["third-party", "Third Party"],
                ].map(([value, label]) => (
                  <Button
                    key={value}
                    aria-pressed={form.transport === value}
                    onClick={() =>
                      setForm({
                        ...form,
                        transport: value,
                        consolePort:
                          value === "udp"
                            ? 8000
                            : value === "tcp"
                              ? 3032
                              : 3037,
                      })
                    }
                  >
                    {label}
                  </Button>
                ))}
              </div>
              <small>
                {form.transport === "third-party"
                  ? "SLIP framing · Eos 3.1 or later"
                  : form.transport === "tcp"
                    ? "OSC 1.0 · Original Element"
                    : "Separate send and receive ports"}
              </small>
            </div>
            <label>
              Console {form.transport === "udp" ? "receive" : "TCP"} port
              <input
                type="number"
                min="1024"
                max="65535"
                value={form.consolePort}
                onChange={(e) =>
                  setForm({ ...form, consolePort: e.target.value })
                }
              />
            </label>
            {form.transport === "udp" && (
              <label>
                {isNativeIOS
                  ? "This device’s receive port"
                  : "Server receive port"}
                <input
                  type="number"
                  min="1024"
                  max="65535"
                  value={form.receivePort}
                  onChange={(e) =>
                    setForm({ ...form, receivePort: e.target.value })
                  }
                />
              </label>
            )}
            <button className="primary-button" disabled={saving}>
              {saving ? "Saving…" : "Save & connect"}
            </button>
            {saved && <p role="status">Settings saved.</p>}
          </form>
        ) : (
          <p>Loading settings…</p>
        )}
        {error && (
          <p className="error" role="alert">
            {error}
          </p>
        )}
        <p className="feedback">
          {isNativeIOS ? "On-device OSC" : "Browser bridge"}{" "}
          <b>{status.bridge ? "Ready" : "Reconnecting"}</b>
        </p>
        <p className="feedback">
          OSC socket <b>{status.udpReady ? "Ready" : "Disconnected"}</b>
        </p>
        <p className="feedback">
          Console{" "}
          <b>
            {status.consoleOnline
              ? "Responding"
              : status.configured
                ? "Awaiting reply"
                : "Not configured"}
          </b>
        </p>
        <p className="feedback">
          {isNativeIOS
            ? "Device ↔ console round trip"
            : "Server ↔ console round trip"}{" "}
          <b>
            {status.consoleOnline && status.latencyMs !== null
              ? status.latencyMs + " ms"
              : "—"}
          </b>
        </p>
        {status.error && <p className="error">{status.error}</p>}
      </Panel>
      <Panel>
        <details className="setup-guide">
          <summary>How to connect</summary>
          <h3>Original Element setup</h3>
          <ol>
            <li>
              Enable OSC receive/transmit in Show Control and the network
              interface.
            </li>
            <li>
              For original Element, use TCP port 3032 with OSC 1.0 packet-length
              framing. Match the console’s configured mode.
            </li>
            <li>
              Third Party OSC uses port 3037 and SLIP framing; it requires Eos
              3.1 or later and must be enabled on the console.
            </li>
            <li>
              {isNativeIOS
                ? "For UDP, set the console’s transmit address to your iPhone/iPad Wi-Fi IP and match its transmit port to this device’s receive port."
                : "For UDP, match receive/transmit ports and set the console’s transmit address to this server’s LAN IP."}
            </li>
          </ol>
          <p className="hint">
            {isNativeIOS
              ? "Allow Local Network access when iOS asks. This app does not need internet or a separate server, but must be on a network that can reach Element."
              : "The browser can be remote; this server still needs a network route to the console. The example IP is not automatically used."}
          </p>
          <a
            className="text-link"
            href="https://support.etcconnect.com/ETC/Consoles/Eos_Family/Software_and_Programming/TCP_port_for_OSC_communication_with_Eos_Software"
            target="_blank"
            rel="noreferrer"
          >
            ETC connection reference ↗
          </a>
        </details>
      </Panel>
    </>
  );
}
createRoot(document.getElementById("root")).render(<App />);
connect();
