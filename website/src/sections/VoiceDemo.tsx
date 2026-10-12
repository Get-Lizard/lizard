import { motion, useInView, useReducedMotion } from "motion/react";
import { useEffect, useRef, useState } from "react";
import { Mark } from "../Mark";

const scenes = [
  { app: "Slack", said: "um hey Ana, the payments fix is live, can you check checkout on staging", typed: "Hey Ana, the payments fix is live. Can you check checkout on staging?" },
  { app: "Lizard search", said: "fifteen percent of two thousand three hundred forty", typed: "15% of 2340" },
  { app: "Mail", said: "thanks for the quick review uh I'll merge it this afternoon", typed: "Thanks for the quick review. I'll merge it this afternoon." },
];

/** Hold ⌃⌥V, talk, release: the words arrive in the pill, then land, tidied, in the app. */
export function VoiceDemo() {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const inView = useInView(ref, { margin: "-20%" });
  const [scene, setScene] = useState(0);
  const [heard, setHeard] = useState("");
  const [typed, setTyped] = useState("");
  const [holding, setHolding] = useState(false);
  const current = scenes[scene];

  useEffect(() => {
    if (reduce) {
      setTyped(current.typed);
      return;
    }
    if (!inView) return;
    setHeard("");
    setTyped("");
    setHolding(true);
    const words = current.said.split(" ");
    let i = 0;
    const timers: number[] = [];
    const finalWords = current.typed.split(" ");
    const listen = window.setInterval(() => {
      i += 1;
      setHeard(words.slice(0, i).join(" "));
      // Live typing: phrases land in the app while you're still talking (a few words behind).
      const settled = Math.max(0, Math.round(((i - 3) / words.length) * finalWords.length));
      setTyped(finalWords.slice(0, settled).join(" "));
      if (i >= words.length) {
        window.clearInterval(listen);
        timers.push(window.setTimeout(() => { setHolding(false); setTyped(current.typed); }, 450));
        timers.push(window.setTimeout(() => setScene((s) => (s + 1) % scenes.length), 4200));
      }
    }, 190);
    return () => {
      window.clearInterval(listen);
      timers.forEach(window.clearTimeout);
    };
  }, [scene, inView, reduce, current]);

  return (
    <section id="voice" className="relative overflow-hidden">
      <div aria-hidden className="pointer-events-none absolute left-1/2 top-1/2 h-[520px] w-[900px] -translate-x-1/2 -translate-y-1/2 rounded-full bg-[radial-gradient(closest-side,color-mix(in_oklab,var(--accent)_16%,transparent),transparent)] blur-2xl" />
      <div className="relative mx-auto max-w-[1240px] px-4 py-28 md:px-8 md:py-36">
        <div className="mx-auto max-w-[720px] text-center">
          <h2 className="text-4xl font-semibold leading-[1.05] tracking-[-0.03em] md:text-6xl">Talk. It types.</h2>
          <p className="mx-auto mt-5 max-w-[54ch] text-[17px] leading-relaxed text-muted">
            Hold <span className="kbd">⌃</span> <span className="kbd">⌥</span> <span className="kbd">V</span> in any app and talk. Your words are typed where your cursor is while you speak, punctuated and without the "um"s. Search Lizard or ask its AI the same way. All on your Mac.
          </p>
        </div>

        <div ref={ref} className="mx-auto mt-16 max-w-[760px]">
          <div className="overflow-hidden rounded-[22px] border border-line bg-raised shadow-[0_30px_80px_-30px_rgb(var(--shadow)/0.7)]">
            <div className="border-b border-line px-6 py-3.5 text-[13px] text-faint">Typing in {current.app}</div>
            <div className="min-h-[120px] p-7 text-[19px] leading-relaxed md:text-[21px]">
              <span>{typed}</span>
              {!reduce && <span className="caret ml-0.5" aria-hidden />}
            </div>
          </div>

          {/* The listening pill, as it looks in the app. */}
          <motion.div
            animate={{ opacity: holding || reduce ? 1 : 0.35, y: holding ? 0 : 6, scale: holding ? 1 : 0.98 }}
            transition={{ duration: 0.35 }}
            className="mx-auto mt-8 flex h-14 max-w-[520px] items-center gap-3 rounded-full border border-accent/50 bg-[#0e1210]/90 px-4 text-white shadow-[0_0_40px_-8px_color-mix(in_oklab,var(--accent)_60%,transparent)] backdrop-blur"
          >
            <Mark size={26} animate={false} />
            <Wave active={holding && !reduce} />
            <span className="min-w-0 flex-1 truncate text-[15px] font-medium [direction:rtl] text-left">
              <span className="[direction:ltr] [unicode-bidi:plaintext]">{reduce ? current.said : heard || "Listening…"}</span>
            </span>
            <span className="shrink-0 text-[11.5px] text-white/50">{holding ? "typing as you talk" : "done"}</span>
          </motion.div>

          <div className="mt-10 grid gap-4 text-center text-[14px] text-muted sm:grid-cols-3">
            <p><span className="font-semibold text-ink">Instant</span>: typed while you talk</p>
            <p><span className="font-semibold text-ink">Tap</span> for hands-free, pause to finish</p>
            <p><span className="font-semibold text-ink">Private</span>: Apple's on-device speech engine</p>
          </div>
        </div>
      </div>
    </section>
  );
}

function Wave({ active }: { active: boolean }) {
  return (
    <span className="flex h-6 shrink-0 items-center gap-[3px]" aria-hidden>
      {Array.from({ length: 12 }, (_, i) => (
        <span
          key={i}
          className="w-[3px] rounded-full bg-gradient-to-b from-accent to-accent-deep"
          style={{
            height: active ? undefined : 4,
            animation: active ? `voicebar 0.9s ${i * 0.07}s ease-in-out infinite` : undefined,
          }}
        />
      ))}
    </span>
  );
}
