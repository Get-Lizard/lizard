import { motion, useReducedMotion, useScroll, useTransform } from "motion/react";
import { useRef } from "react";
import { InstallCommand } from "../Install";
import { Mark } from "../Mark";

const rise = {
  hidden: { opacity: 0, y: 18 },
  show: (i: number) => ({ opacity: 1, y: 0, transition: { delay: 0.15 + i * 0.08, duration: 0.8, ease: [0.16, 1, 0.3, 1] as const } }),
};

export function Hero() {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start start", "end start"] });
  // The product tilts back as you scroll past it (depth cue toward the next section).
  const rotate = useTransform(scrollYProgress, [0, 1], [0, reduce ? 0 : 8]);
  const y = useTransform(scrollYProgress, [0, 1], [0, reduce ? 0 : 90]);

  return (
    <section id="top" ref={ref} className="relative overflow-hidden">
      <div aria-hidden className="pointer-events-none absolute -top-40 right-[-10%] h-[720px] w-[900px] rounded-full bg-[radial-gradient(closest-side,color-mix(in_oklab,var(--accent)_22%,transparent),transparent)] blur-2xl" />
      <div className="mx-auto grid min-h-[calc(100dvh-4rem)] max-w-[1240px] grid-cols-1 items-center gap-14 px-4 pb-16 pt-12 md:px-8 lg:grid-cols-[1fr_1.15fr] lg:gap-10 lg:pt-16">
        <div className="relative z-10 min-w-0 max-w-[560px]">
          <motion.div variants={rise} initial={reduce ? false : "hidden"} animate="show" custom={0} className="mb-7">
            <Mark size={64} />
          </motion.div>
          <motion.p variants={rise} initial={reduce ? false : "hidden"} animate="show" custom={1} className="mb-4 text-[13px] font-medium uppercase tracking-[0.16em] text-accent">
            Press ⌃ Space
          </motion.p>
          <motion.h1
            variants={rise} initial={reduce ? false : "hidden"} animate="show" custom={2}
            className="text-[44px] font-semibold leading-[1.02] tracking-[-0.035em] sm:text-6xl lg:text-[68px]"
          >
            Your whole Mac,
            <br />
            <span className="bg-gradient-to-r from-accent to-accent-deep bg-clip-text text-transparent">one keystroke away.</span>
          </motion.h1>
          <motion.p variants={rise} initial={reduce ? false : "hidden"} animate="show" custom={3} className="mt-6 max-w-[46ch] text-[18px] leading-relaxed text-muted">
            A native launcher with a private AI that knows your notes. Apps, clipboard, screenshots and windows, all in one shortcut.
          </motion.p>
          <motion.div variants={rise} initial={reduce ? false : "hidden"} animate="show" custom={4} className="mt-9 flex flex-col items-start gap-4">
            <InstallCommand large />
            <a href="#ai" className="text-[14px] font-medium text-muted underline decoration-line-strong underline-offset-4 transition-colors hover:text-ink">
              See what it does
            </a>
          </motion.div>
        </div>

        <motion.div
          initial={reduce ? false : { opacity: 0, y: 40, scale: 0.97 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          transition={{ delay: 0.35, duration: 1.1, ease: [0.16, 1, 0.3, 1] }}
          className="relative min-w-0 [perspective:1600px]"
        >
          <motion.img
            style={{ rotateX: rotate, y }}
            src="./shots/home.png"
            width={1680}
            height={1061}
            alt="Lizard's launcher: a search field, a greeting, quick tiles for Ask AI, Clipboard, Notes and Screenshots, and recent commands"
            className="screen w-full origin-top"
          />
        </motion.div>
      </div>
    </section>
  );
}
