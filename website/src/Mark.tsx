import { motion, useReducedMotion } from "motion/react";
import paths from "./lizard-paths.json";

/** The Lizard gecko, from the app's own geometry: its outline draws in, then the body fills. */
export function Mark({ size = 40, animate = true, className = "" }: { size?: number; animate?: boolean; className?: string }) {
  const reduce = useReducedMotion();
  const play = animate && !reduce;
  const id = `g-${size}`;
  return (
    <svg viewBox="0 0 100 100" width={size} height={size} className={className} role="img" aria-label="Lizard">
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="var(--accent)" />
          <stop offset="1" stopColor="var(--accent-deep)" />
        </linearGradient>
      </defs>
      {play && (
        <motion.path
          d={paths.centerline}
          fill="none"
          stroke={`url(#${id})`}
          strokeWidth={2.2}
          strokeLinecap="round"
          strokeLinejoin="round"
          initial={{ pathLength: 0, opacity: 1 }}
          whileInView={{ pathLength: 1, opacity: [1, 1, 0] }}
          viewport={{ once: true }}
          transition={{ pathLength: { duration: 1.3, ease: [0.65, 0, 0.35, 1] }, opacity: { duration: 1.9, times: [0, 0.7, 1] } }}
        />
      )}
      <motion.path
        d={paths.silhouette}
        fill={`url(#${id})`}
        fillRule="evenodd"
        initial={play ? { opacity: 0, scale: 0.94 } : false}
        whileInView={{ opacity: 1, scale: 1 }}
        viewport={{ once: true }}
        transition={{ delay: play ? 1.1 : 0, duration: 0.6, ease: [0.16, 1, 0.3, 1] }}
        style={{ transformOrigin: "50% 55%" }}
      />
    </svg>
  );
}
