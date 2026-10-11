import { motion, useReducedMotion, useScroll, useTransform } from "motion/react";
import { useRef } from "react";

/** Setup, as it really looks: the gecko that walks in, and the shortcut picker. Fanned out by scroll. */
export function FirstRun() {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLElement>(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start end", "end start"] });
  const left = useTransform(scrollYProgress, [0, 0.5], reduce ? [0, 0] : [-14, -6]);
  const right = useTransform(scrollYProgress, [0, 0.5], reduce ? [0, 0] : [14, 6]);
  const lift = useTransform(scrollYProgress, [0, 0.5], reduce ? [0, 0] : [80, 0]);

  return (
    <section ref={ref} className="relative mx-auto max-w-[1240px] overflow-hidden px-4 py-28 md:px-8 md:py-36">
      <div className="mx-auto max-w-[720px] text-center">
        <h2 className="text-4xl font-semibold leading-[1.05] tracking-[-0.03em] md:text-6xl">One minute to set up. A gecko says hi.</h2>
        <p className="mx-auto mt-5 max-w-[54ch] text-[17px] leading-relaxed text-muted">
          Pick ⌘ Space (Lizard moves Spotlight out of the way) or your own shortcut, allow paste, choose your AI, and bring your Raycast extensions, quicklinks and snippets.
        </p>
      </div>
      <div className="relative mt-16 flex items-center justify-center [perspective:1800px]">
        <motion.img
          src="./shots/shortcuts.webp"
          alt="Setup: pick your shortcut, with ⌘ Space recommended"
          loading="lazy"
          style={{ rotateY: right, y: lift }}
          className="screen relative z-0 hidden w-[44%] translate-x-[18%] md:block"
        />
        <motion.img
          src="./shots/welcome.webp"
          alt="Setup's welcome page: the gecko walks in under a green aurora"
          loading="lazy"
          style={{ rotateY: left }}
          className="screen relative z-10 w-full max-w-[560px] md:w-[48%] md:-translate-x-[6%]"
        />
      </div>
    </section>
  );
}
