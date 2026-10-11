import { motion, useReducedMotion } from "motion/react";
import paths from "./lizard-paths.json";

/** Slow aurora blobs and rising fireflies, the same mood as the app's welcome screen. */
export function Aurora({ className = "" }: { className?: string }) {
  return (
    <div aria-hidden className={`pointer-events-none absolute inset-0 overflow-hidden ${className}`}>
      <div className="aurora-blob left-[-10%] top-[-20%] h-[620px] w-[620px] bg-[radial-gradient(closest-side,color-mix(in_oklab,var(--accent)_30%,transparent),transparent)]" />
      <div className="aurora-blob aurora-b right-[-12%] top-[5%] h-[700px] w-[760px] bg-[radial-gradient(closest-side,color-mix(in_oklab,var(--accent-deep)_26%,transparent),transparent)]" />
      <div className="aurora-blob aurora-c bottom-[-30%] left-[30%] h-[560px] w-[560px] bg-[radial-gradient(closest-side,color-mix(in_oklab,var(--accent)_18%,transparent),transparent)]" />
      <Fireflies />
    </div>
  );
}

/** Deterministic positions so server and client agree and nothing jumps. */
const flies = Array.from({ length: 34 }, (_, i) => {
  const r = (n: number) => Math.abs(Math.sin(i * 12.9898 + n * 78.233) * 43758.5453) % 1;
  return { left: r(1) * 100, delay: r(2) * -18, duration: 12 + r(3) * 14, size: r(4) > 0.8 ? 3 : 2, drift: (r(5) - 0.5) * 60 };
});

function Fireflies() {
  return (
    <>
      {flies.map((fly, i) => (
        <span
          key={i}
          className="firefly"
          style={{
            left: `${fly.left}%`,
            width: fly.size,
            height: fly.size,
            animationDelay: `${fly.delay}s`,
            animationDuration: `${fly.duration}s`,
            ["--drift" as string]: `${fly.drift}px`,
          }}
        />
      ))}
    </>
  );
}

/** A small gecko that wanders across the bottom of a section, tail swaying as it walks. */
export function WanderingGecko({ duration = 22, delay = 2 }: { duration?: number; delay?: number }) {
  const reduce = useReducedMotion();
  if (reduce) return null;
  return (
    <motion.div
      aria-hidden
      className="pointer-events-none absolute bottom-6 left-0 z-0"
      initial={{ x: "-12vw" }}
      animate={{ x: "112vw" }}
      transition={{ duration, delay, repeat: Infinity, repeatDelay: 6, ease: "linear" }}
    >
      <motion.svg
        viewBox="0 0 100 100"
        width={46}
        height={46}
        style={{ rotate: 90 }}
        animate={{ rotate: [84, 96, 84] }}
        transition={{ duration: 0.7, repeat: Infinity, ease: "easeInOut" }}
      >
        <path d={paths.silhouette} fill="var(--accent)" fillRule="evenodd" opacity={0.55} />
      </motion.svg>
    </motion.div>
  );
}
