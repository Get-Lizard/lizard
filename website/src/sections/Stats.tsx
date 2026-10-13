import { animate, motion, useInView, useReducedMotion } from "motion/react";
import { useEffect, useRef, useState } from "react";

const stats = [
  { value: 3, suffix: " ms", label: "from ⌘ Space to typing" },
  { value: 0, suffix: "", label: "accounts, servers or trackers" },
  { value: 211, suffix: "", label: "automated tests on every change" },
  { value: 100, suffix: "%", label: "on-device AI until you say otherwise" },
];

function Counter({ to, suffix }: { to: number; suffix: string }) {
  const ref = useRef<HTMLSpanElement>(null);
  const inView = useInView(ref, { once: true, margin: "-80px" });
  const reduce = useReducedMotion();
  const [shown, setShown] = useState(reduce ? to : 0);
  useEffect(() => {
    if (!inView || reduce) return;
    const controls = animate(0, to, { duration: 1.4, ease: [0.16, 1, 0.3, 1], onUpdate: (v) => setShown(Math.round(v)) });
    return () => controls.stop();
  }, [inView, reduce, to]);
  return (
    <span ref={ref} className="tabular-nums">
      {shown}
      {suffix}
    </span>
  );
}

/** Four numbers that count up as they arrive. */
export function Stats() {
  return (
    <section aria-label="Lizard in numbers" className="border-y border-line bg-sunken/60">
      <div className="mx-auto grid max-w-[1240px] grid-cols-2 gap-y-10 px-4 py-14 md:grid-cols-4 md:px-8">
        {stats.map((stat, i) => (
          <motion.div
            key={stat.label}
            initial={{ opacity: 0, y: 16 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true }}
            transition={{ delay: i * 0.08, duration: 0.6, ease: [0.16, 1, 0.3, 1] }}
            className="px-2"
          >
            <p className="bg-gradient-to-br from-accent to-accent-deep bg-clip-text text-5xl font-semibold tracking-[-0.04em] text-transparent md:text-6xl">
              <Counter to={stat.value} suffix={stat.suffix} />
            </p>
            <p className="mt-2 max-w-[22ch] text-[14.5px] text-muted">{stat.label}</p>
          </motion.div>
        ))}
      </div>
    </section>
  );
}
