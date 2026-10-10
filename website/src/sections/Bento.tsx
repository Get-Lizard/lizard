import { motion, useReducedMotion } from "motion/react";
import { ClipboardText, Camera, Rectangle, SquareSplitHorizontal, SquareSplitVertical, ArrowsOut } from "@phosphor-icons/react";
import type { ReactNode } from "react";

function Cell({ className = "", index, children }: { className?: string; index: number; children: ReactNode }) {
  const reduce = useReducedMotion();
  return (
    <motion.div
      initial={reduce ? false : { opacity: 0, y: 28 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, amount: 0.25 }}
      transition={{ duration: 0.7, delay: index * 0.07, ease: [0.16, 1, 0.3, 1] }}
      className={`relative overflow-hidden rounded-[22px] border border-line p-7 md:p-8 ${className}`}
    >
      {children}
    </motion.div>
  );
}

const categories = ["Code", "Errors", "Terminal", "Receipts", "Design", "Chats"];

/** Five features, five cells: an asymmetric grid, each with its own visual. */
export function Bento() {
  return (
    <section id="features" className="mx-auto max-w-[1240px] px-4 py-28 md:px-8 md:py-36">
      <h2 className="max-w-[18ch] text-4xl font-semibold leading-[1.05] tracking-[-0.03em] md:text-5xl">Everything you reach for, without reaching.</h2>
      <p className="mt-5 max-w-[56ch] text-[17px] leading-relaxed text-muted">The panel opens over whatever you are doing, never steals focus, and reopens exactly where you left it.</p>

      <div className="mt-14 grid gap-4 md:grid-cols-6 md:grid-rows-[auto_auto]">
        {/* 1. Fuzzy search: real screen */}
        <Cell index={0} className="bg-raised md:col-span-4 md:row-span-2">
          <h3 className="text-2xl font-semibold tracking-[-0.02em]">Three letters is enough.</h3>
          <p className="mt-2 max-w-[44ch] text-muted">Type <span className="font-mono text-ink">vsc</span> and Visual Studio Code is on top. What you open often rises on its own.</p>
          <img src="./shots/search.png" width={1680} height={1061} alt="Typing vsc finds Visual Studio Code, with the matched letters highlighted" loading="lazy" className="screen mt-8 w-full md:translate-x-10 md:translate-y-2" />
        </Cell>

        {/* 2. Calculator: typography as the visual */}
        <Cell index={1} className="bg-[linear-gradient(160deg,color-mix(in_oklab,var(--accent)_16%,var(--bg-raised)),var(--bg-raised)_70%)] md:col-span-2">
          <p className="font-mono text-[15px] text-muted">15% of 80</p>
          <p className="mt-1 font-mono text-6xl font-medium tracking-tight text-accent">= 12</p>
          <h3 className="mt-6 text-xl font-semibold">A calculator in the search field.</h3>
          <p className="mt-1.5 text-[15px] text-muted">Percentages, powers, and units like <span className="font-mono text-ink">5 km in mi</span>.</p>
        </Cell>

        {/* 3. Clipboard */}
        <Cell index={2} className="bg-raised md:col-span-2">
          <ClipboardText size={34} weight="duotone" className="text-accent" />
          <h3 className="mt-5 text-xl font-semibold">Everything you copied.</h3>
          <p className="mt-1.5 text-[15px] text-muted">Search it, pin it, paste it back with Return. Passwords from password managers are never stored.</p>
        </Cell>

        {/* 4. Screenshots: categories as stacked type */}
        <Cell index={3} className="bg-sunken md:col-span-3">
          <div className="flex items-start justify-between gap-6">
            <div>
              <Camera size={34} weight="duotone" className="text-accent" />
              <h3 className="mt-5 text-xl font-semibold">Screenshots that file themselves.</h3>
              <p className="mt-1.5 max-w-[34ch] text-[15px] text-muted">Lizard reads the text, names the capture and sorts it into a folder. You can search what is inside them.</p>
            </div>
            <ul aria-label="Screenshot categories" className="hidden select-none text-right font-semibold leading-[1.05] tracking-[-0.03em] sm:block">
              {categories.map((name, i) => (
                <li key={name} className="text-[26px]" style={{ opacity: 1 - i * 0.15 }}>{name}</li>
              ))}
            </ul>
          </div>
        </Cell>

        {/* 5. Windows: real layout glyphs */}
        <Cell index={4} className="bg-raised md:col-span-3">
          <div className="flex gap-3 text-accent" aria-hidden>
            <SquareSplitHorizontal size={34} weight="duotone" />
            <SquareSplitVertical size={34} weight="duotone" />
            <ArrowsOut size={34} weight="duotone" />
            <Rectangle size={34} weight="duotone" />
          </div>
          <h3 className="mt-5 text-xl font-semibold">Windows where you want them.</h3>
          <p className="mt-1.5 max-w-[44ch] text-[15px] text-muted">Halves, thirds, quarters, maximize and the next display, from the keyboard.</p>
        </Cell>
      </div>
    </section>
  );
}
