import { AnimatePresence, motion, useMotionValue, useReducedMotion, useSpring, useTransform } from "motion/react";
import { useEffect, useState } from "react";

/** Real captures of the app, played like a demo: the query types itself, the screen follows. */
const frames = [
  { src: "./shots/home.webp", query: "", label: "⌘ Space", alt: "Lizard's home: search field, quick tiles and recent commands" },
  { src: "./shots/calc.webp", query: "15% of 2340", label: "Calculator", alt: "Typing 15% of 2340 shows a calculator card: 351, three hundred fifty-one" },
  { src: "./shots/translate.webp", query: "good morning, how are you? in spanish", label: "Translate", alt: "Typing a sentence in spanish shows the translation instantly, on device" },
  { src: "./shots/search.webp", query: "snip", label: "Commands", alt: "Typing snip lists Create, Import, Export and Search Snippets" },
  { src: "./shots/quicklink.webp", query: "linear.app/team/search", label: "Quicklinks", alt: "The quicklink editor with Open With set to Google Chrome" },
];

export function LiveDemo() {
  const reduce = useReducedMotion();
  const [index, setIndex] = useState(0);
  const [typed, setTyped] = useState("");
  const frame = frames[index];

  // Type the query, hold, move on.
  useEffect(() => {
    if (reduce) {
      setTyped(frame.query);
      return;
    }
    setTyped("");
    let i = 0;
    const type = window.setInterval(() => {
      i += 1;
      setTyped(frame.query.slice(0, i));
      if (i >= frame.query.length) window.clearInterval(type);
    }, 42);
    const next = window.setTimeout(() => setIndex((n) => (n + 1) % frames.length), Math.max(2800, frame.query.length * 42 + 2200));
    return () => {
      window.clearInterval(type);
      window.clearTimeout(next);
    };
  }, [index, frame.query, reduce]);

  // Gentle 3D tilt toward the pointer.
  const px = useMotionValue(0);
  const py = useMotionValue(0);
  const rotateY = useSpring(useTransform(px, [-0.5, 0.5], [-7, 7]), { stiffness: 120, damping: 18 });
  const rotateX = useSpring(useTransform(py, [-0.5, 0.5], [6, -6]), { stiffness: 120, damping: 18 });

  return (
    <div
      className="relative [perspective:1600px]"
      onPointerMove={(e) => {
        if (reduce) return;
        const box = e.currentTarget.getBoundingClientRect();
        px.set((e.clientX - box.left) / box.width - 0.5);
        py.set((e.clientY - box.top) / box.height - 0.5);
      }}
      onPointerLeave={() => {
        px.set(0);
        py.set(0);
      }}
    >
      <div className="mb-4 flex items-center gap-3">
        <span className="inline-flex h-8 items-center gap-2 rounded-full border border-line-strong bg-raised/80 px-3 font-mono text-[13px] text-ink backdrop-blur">
          <span className="text-accent">{frame.label}</span>
          {frame.query && <span className="text-faint">·</span>}
          <span>{typed}</span>
          {!reduce && <span className="caret !h-[1em] !w-[0.45em]" aria-hidden />}
        </span>
        <div className="ml-auto flex gap-1.5" aria-hidden>
          {frames.map((f, i) => (
            <button
              key={f.src}
              type="button"
              onClick={() => setIndex(i)}
              aria-label={`Show ${f.label}`}
              className={`h-1.5 rounded-full transition-all duration-500 ${i === index ? "w-6 bg-accent" : "w-1.5 bg-line-strong hover:bg-muted"}`}
            />
          ))}
        </div>
      </div>
      <motion.div style={{ rotateX, rotateY }} className="relative aspect-[1520/960] w-full [transform-style:preserve-3d]">
        <div aria-hidden className="absolute -inset-8 -z-10 rounded-[40px] bg-[radial-gradient(closest-side,color-mix(in_oklab,var(--accent)_28%,transparent),transparent)] blur-2xl" />
        <AnimatePresence mode="popLayout" initial={false}>
          <motion.img
            key={frame.src}
            src={frame.src}
            alt={frame.alt}
            width={1520}
            height={960}
            className="screen absolute inset-0 h-full w-full object-cover object-top"
            initial={reduce ? false : { opacity: 0, scale: 0.96, filter: "blur(10px)", y: 14 }}
            animate={{ opacity: 1, scale: 1, filter: "blur(0px)", y: 0 }}
            exit={reduce ? undefined : { opacity: 0, scale: 1.03, filter: "blur(8px)", y: -10 }}
            transition={{ duration: 0.65, ease: [0.16, 1, 0.3, 1] }}
          />
        </AnimatePresence>
      </motion.div>
      {/* Preload the rest so each switch is instant. */}
      <div className="hidden">{frames.map((f) => <img key={f.src} src={f.src} alt="" loading="eager" />)}</div>
    </div>
  );
}
