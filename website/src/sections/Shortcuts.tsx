import { motion, useReducedMotion } from "motion/react";
import { Sparkle, ClipboardText, ListChecks, Camera, ArrowsLeftRight, Command } from "@phosphor-icons/react";

const shortcuts = [
  { keys: ["⇥"], label: "Ask AI about what you typed", icon: Sparkle },
  { keys: ["⌥", "⇧", "V"], label: "Clipboard history", icon: ClipboardText },
  { keys: ["⌥", "⇧", "W"], label: "Log what you just finished", icon: ListChecks },
  { keys: ["⌃", "⇧", "S"], label: "Capture and file a screenshot", icon: Camera },
  { keys: ["⌃", "⌥", "←"], label: "Snap a window", icon: ArrowsLeftRight },
  { keys: ["⌘", "K"], label: "Actions for anything", icon: Command },
];

function Key({ children, big = false, press = false, delay = 0 }: { children: string; big?: boolean; press?: boolean; delay?: number }) {
  const reduce = useReducedMotion();
  return (
    <motion.kbd
      animate={press && !reduce ? { y: [0, 0, 4, 0, 0] } : undefined}
      transition={press ? { duration: 2.6, times: [0, 0.55, 0.62, 0.72, 1], repeat: Infinity, delay } : undefined}
      className={`keycap inline-flex items-center justify-center rounded-xl border border-line-strong bg-raised font-sans font-medium text-ink ${big ? "h-24 min-w-24 px-7 text-4xl md:h-28 md:min-w-28 md:text-5xl" : "h-9 min-w-9 px-2.5 text-[15px]"}`}
    >
      {children}
    </motion.kbd>
  );
}

/** Keyboard-first: one big shortcut being pressed (teaches it), then the rest. */
export function Shortcuts() {
  return (
    <section id="shortcuts" className="mx-auto max-w-[1240px] px-4 py-28 md:px-8 md:py-36">
      <div className="flex flex-col items-start gap-10 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <h2 className="max-w-[14ch] text-4xl font-semibold leading-[1.05] tracking-[-0.03em] md:text-5xl">Built for the keyboard.</h2>
          <p className="mt-5 max-w-[44ch] text-[17px] leading-relaxed text-muted">Every shortcut can be re-recorded in setup. The one you will use most:</p>
        </div>
        <div className="flex items-center gap-4" aria-label="Control Space">
          <Key big press>⌃</Key>
          <span className="text-3xl text-faint">+</span>
          <Key big press delay={0.04}>Space</Key>
        </div>
      </div>

      <div className="mt-16 grid gap-x-12 gap-y-2 md:grid-cols-2">
        {shortcuts.map(({ keys, label, icon: Icon }) => (
          <div key={label} className="flex items-center justify-between gap-6 border-b border-line py-5">
            <span className="flex items-center gap-3 text-[16px]">
              <Icon size={20} weight="duotone" className="text-accent" />
              {label}
            </span>
            <span className="flex gap-1.5">
              {keys.map((key) => (
                <Key key={key}>{key}</Key>
              ))}
            </span>
          </div>
        ))}
      </div>
    </section>
  );
}
