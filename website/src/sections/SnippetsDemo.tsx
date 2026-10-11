import { motion, useInView, useReducedMotion } from "motion/react";
import { useEffect, useRef, useState } from "react";

const today = new Date().toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long", year: "numeric" });

const scenes = [
  { keyword: ";sig", expanded: "Best,\nAna Costa\nPayments team", app: "Mail" },
  { keyword: ";date", expanded: today, app: "Notes" },
  { keyword: ";standup", expanded: "Yesterday: shipped quicklinks\nToday: snippets\nBlockers: none", app: "Slack" },
];

const placeholders = ["{clipboard}", "{date}", "{cursor}", "{selection}", "{uuid}", "{clipboard | uppercase}", '{date offset="+1d"}', '{snippet name="sig"}'];

/** A keyword typed in some app turns into the snippet, the way it really does with Lizard. */
export function SnippetsDemo() {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const inView = useInView(ref, { margin: "-20%" });
  const [scene, setScene] = useState(0);
  const [text, setText] = useState("");
  const [expanded, setExpanded] = useState(false);
  const current = scenes[scene];

  useEffect(() => {
    if (reduce) {
      setText(current.expanded);
      setExpanded(true);
      return;
    }
    if (!inView) return;
    setExpanded(false);
    setText("");
    let i = 0;
    const timers: number[] = [];
    const type = window.setInterval(() => {
      i += 1;
      setText(current.keyword.slice(0, i));
      if (i >= current.keyword.length) {
        window.clearInterval(type);
        timers.push(window.setTimeout(() => { setExpanded(true); setText(current.expanded); }, 420));
        timers.push(window.setTimeout(() => setScene((s) => (s + 1) % scenes.length), 3600));
      }
    }, 140);
    return () => {
      window.clearInterval(type);
      timers.forEach(window.clearTimeout);
    };
  }, [scene, inView, reduce, current]);

  return (
    <section id="snippets" className="relative overflow-hidden border-y border-line bg-sunken">
      <div className="mx-auto grid max-w-[1240px] grid-cols-1 items-center gap-14 px-4 py-28 md:px-8 md:py-36 lg:grid-cols-[1fr_1.05fr] lg:gap-20">
        <div className="min-w-0">
          <h2 className="max-w-[14ch] text-4xl font-semibold leading-[1.05] tracking-[-0.03em] md:text-5xl">Type less. Say more.</h2>
          <p className="mt-5 max-w-[48ch] text-[17px] leading-relaxed text-muted">
            Give a snippet a keyword and type it in any app: Mail, Slack, your editor. Lizard swaps it for the full text, puts your clipboard back, and drops the caret where you want it.
          </p>
          <div className="mt-9 flex flex-wrap gap-2">
            {placeholders.map((token, i) => (
              <motion.span
                key={token}
                initial={{ opacity: 0, y: 10 }}
                whileInView={{ opacity: 1, y: 0 }}
                viewport={{ once: true }}
                transition={{ delay: 0.1 + i * 0.05 }}
                className="rounded-lg border border-line bg-raised px-2.5 py-1.5 font-mono text-[12.5px] text-accent"
              >
                {token}
              </motion.span>
            ))}
          </div>
          <p className="mt-6 text-[14px] text-faint">Same placeholders as Raycast, and the same file format: bring your Raycast snippets over in setup.</p>
        </div>

        <div ref={ref} className="min-w-0">
          <div className="overflow-hidden rounded-[22px] border border-line bg-raised shadow-[0_30px_80px_-30px_rgb(var(--shadow)/0.7)]">
            <div className="border-b border-line px-6 py-3.5 text-[13px] text-faint">Typing in {current.app}</div>
            <div className="min-h-[220px] whitespace-pre-wrap p-7 text-[19px] leading-relaxed md:text-[21px]">
              <motion.span
                key={`${scene}-${expanded}`}
                initial={expanded && !reduce ? { opacity: 0, filter: "blur(6px)" } : false}
                animate={{ opacity: 1, filter: "blur(0px)" }}
                transition={{ duration: 0.45 }}
                className={expanded ? "text-ink" : "font-mono text-accent"}
              >
                {text}
              </motion.span>
              {!reduce && <span className="caret ml-0.5" aria-hidden />}
            </div>
          </div>
          <p className="mt-4 text-center text-[13px] text-faint">
            Typed <span className="font-mono text-muted">{current.keyword}</span>, got the snippet. Never fires in password fields.
          </p>
        </div>
      </div>
    </section>
  );
}
