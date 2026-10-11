import { Calculator, ChatsCircle, LinkSimple, ListChecks, NotePencil, Quotes } from "@phosphor-icons/react";
import { AnimatePresence, motion, useInView, useReducedMotion } from "motion/react";
import { useEffect, useRef, useState, type ComponentType } from "react";

type Item = { icon: ComponentType<{ size?: number; weight?: "duotone" }>; title: string; body: string; type?: string; src: string; alt: string };

const items: Item[] = [
  { icon: Calculator, title: "Math, answered as you type", body: "Percentages, units, powers. The result is a card you can copy with Return, even spelled out.", type: "15% of 2340", src: "./shots/calc.webp", alt: "Calculator card: 15% of 2340 is 351" },
  { icon: ChatsCircle, title: "Translate without opening anything", body: "Add “in spanish” to any sentence. Apple Translation answers on device, and Apple Intelligence fills in when a language isn't downloaded.", type: "good morning in spanish", src: "./shots/translate.webp", alt: "Translation card from English to Spanish" },
  { icon: LinkSimple, title: "Quicklinks with your browser", body: "Paste a link and save it. Pick which browser opens it, give it a keyword, add {query} for searches.", type: "linear.app/team", src: "./shots/quicklink.webp", alt: "Quicklink editor with Open With and Icon pickers" },
  { icon: Quotes, title: "Snippets that expand anywhere", body: "Type ;sig in any app and it becomes your signature. Raycast's placeholders work: {clipboard}, {date}, {cursor}.", type: ";sig", src: "./shots/snippet.webp", alt: "Snippet editor with a signature and a ;sig keyword" },
  { icon: NotePencil, title: "Notes that look finished", body: "Live Markdown, folders, tags and code blocks with a copy button. Plain files on your Mac.", src: "./shots/notes.webp", alt: "Notes with folders, tags and a code block" },
  { icon: ListChecks, title: "A review written from your work log", body: "Pick last quarter or any dates. Lizard writes your self-review from what you logged.", src: "./shots/review.webp", alt: "Performance Review with period picker and log summary" },
];

function Step({ item, index, active, onActive }: { item: Item; index: number; active: boolean; onActive: (i: number) => void }) {
  const ref = useRef<HTMLLIElement>(null);
  const inView = useInView(ref, { margin: "-45% 0px -45% 0px" });
  useEffect(() => {
    if (inView) onActive(index);
  }, [inView, index, onActive]);
  const Icon = item.icon;
  return (
    <li ref={ref} className={`transition-opacity duration-500 lg:min-h-[62vh] lg:py-[10vh] ${active ? "opacity-100" : "lg:opacity-35"}`}>
      <div className="flex items-center gap-3">
        <span className={`grid h-11 w-11 place-items-center rounded-xl border transition-colors duration-500 ${active ? "border-accent/50 bg-accent/15 text-accent" : "border-line text-muted"}`}>
          <Icon size={22} weight="duotone" />
        </span>
        {item.type && <span className="rounded-md border border-line bg-raised px-2 py-1 font-mono text-[12.5px] text-muted">{item.type}</span>}
      </div>
      <h3 className="mt-5 text-3xl font-semibold leading-[1.1] tracking-[-0.025em] md:text-4xl">{item.title}</h3>
      <p className="mt-3 max-w-[46ch] text-[17px] leading-relaxed text-muted">{item.body}</p>
      {/* Small screens: the screen sits under its text. */}
      <img src={item.src} alt={item.alt} loading="lazy" className="screen mt-7 w-full lg:hidden" />
    </li>
  );
}

/** Scroll through the features; the real screen on the right follows along. */
export function Showcase() {
  const reduce = useReducedMotion();
  const [active, setActive] = useState(0);
  const current = items[active];

  return (
    <section id="features" className="relative mx-auto max-w-[1240px] px-4 py-28 md:px-8 md:py-36">
      <h2 className="max-w-[17ch] text-4xl font-semibold leading-[1.05] tracking-[-0.03em] md:text-6xl">Type anything. Lizard knows what you mean.</h2>
      <p className="mt-5 max-w-[56ch] text-[17px] leading-relaxed text-muted">One field for math, languages, links, snippets and notes. These are real screens from the app.</p>
      <div className="mt-16 grid gap-16 lg:grid-cols-[0.85fr_1.15fr] lg:gap-14">
        <ol className="space-y-20 lg:space-y-0">
          {items.map((item, i) => (
            <Step key={item.title} item={item} index={i} active={i === active} onActive={setActive} />
          ))}
        </ol>
        <div className="relative hidden lg:block">
          <div className="sticky top-[18vh]">
            <div aria-hidden className="absolute -inset-10 rounded-[48px] bg-[radial-gradient(closest-side,color-mix(in_oklab,var(--accent)_22%,transparent),transparent)] blur-2xl" />
            <div className="relative aspect-[1520/960]">
              <AnimatePresence mode="popLayout" initial={false}>
                <motion.img
                  key={current.src}
                  src={current.src}
                  alt={current.alt}
                  className="screen absolute inset-0 h-full w-full object-cover object-top"
                  initial={reduce ? false : { opacity: 0, y: 40, rotateX: 8, scale: 0.97 }}
                  animate={{ opacity: 1, y: 0, rotateX: 0, scale: 1 }}
                  exit={reduce ? undefined : { opacity: 0, y: -30, scale: 0.98 }}
                  transition={{ duration: 0.7, ease: [0.16, 1, 0.3, 1] }}
                />
              </AnimatePresence>
            </div>
            <div className="mt-6 flex gap-2" aria-hidden>
              {items.map((item, i) => (
                <span key={item.title} className={`h-1 flex-1 rounded-full transition-colors duration-500 ${i <= active ? "bg-accent" : "bg-line-strong"}`} />
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
