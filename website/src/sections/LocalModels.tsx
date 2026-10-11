import { AppleLogo, CloudSlash, DownloadSimple, Moon } from "@phosphor-icons/react";
import { motion, useReducedMotion } from "motion/react";
import { useState } from "react";

// Mirrors ModelCatalog.swift: download size, and the fit rule (download × 1.15 + 1.5 GB against
// the GPU budget macOS gives the app, roughly 70% of memory).
const models = [
  { name: "Qwen3 1.7B", gb: 1.0, quality: 52 },
  { name: "Qwen3 4B", gb: 2.3, quality: 66 },
  { name: "Qwen3 8B", gb: 4.6, quality: 76 },
  { name: "Qwen3.5 9B", gb: 6.0, quality: 80 },
  { name: "Qwen3 14B", gb: 8.3, quality: 84 },
  { name: "gpt-oss 20B", gb: 12.1, quality: 85 },
  { name: "Qwen3-Coder 30B", gb: 17.2, quality: 94 },
];
const memories = [8, 16, 24, 36, 64];

type Fit = "great" | "good" | "tight" | "no";
function fit(gb: number, memory: number): Fit {
  const ratio = (gb * 1.15 + 1.5) / (memory * 0.7);
  return ratio < 0.55 ? "great" : ratio < 0.8 ? "good" : ratio < 1 ? "tight" : "no";
}

const fitLabel: Record<Fit, string> = { great: "Runs easily", good: "Runs well", tight: "Tight fit", no: "Too large" };

const facts = [
  { icon: AppleLogo, title: "Apple Intelligence first", body: "Tagging, triage and short answers use the model already in macOS. Nothing to download." },
  { icon: DownloadSimple, title: "Download once, on your terms", body: "A local model downloads only when you pick it, with progress and resume." },
  { icon: Moon, title: "Unloads when idle", body: "After two quiet minutes the model leaves memory, so your other apps get it back." },
  { icon: CloudSlash, title: "Cloud is opt-in", body: "OpenRouter and OpenCode stay off until you sign in and switch them on." },
];

/** Interactive: pick your Mac's memory, see which models Lizard would run and which it picks. */
export function LocalModels() {
  const reduce = useReducedMotion();
  const [memory, setMemory] = useState(16);
  const pick = models.filter((m) => ["great", "good"].includes(fit(m.gb, memory))).sort((a, b) => b.quality - a.quality)[0];
  const max = 17.2 * 1.15 + 1.5;

  return (
    <section id="models" className="mx-auto max-w-[1240px] px-4 py-28 md:px-8 md:py-36">
      <div className="grid grid-cols-1 gap-14 lg:grid-cols-[0.9fr_1.1fr] lg:gap-20">
        <div>
          <h2 className="max-w-[14ch] text-4xl font-semibold leading-[1.05] tracking-[-0.03em] md:text-5xl">A model sized to your Mac.</h2>
          <p className="mt-5 max-w-[46ch] text-[17px] leading-relaxed text-muted">
            Lizard reads how much memory your Mac can give the GPU and suggests the strongest model that still leaves room for your work. It runs on Apple silicon with MLX.
          </p>
          <dl className="mt-12 grid gap-8 sm:grid-cols-2">
            {facts.map(({ icon: Icon, title, body }) => (
              <div key={title}>
                <Icon size={22} weight="duotone" className="text-accent" />
                <dt className="mt-3 font-semibold">{title}</dt>
                <dd className="mt-1.5 text-[15px] leading-relaxed text-muted">{body}</dd>
              </div>
            ))}
          </dl>
        </div>

        <div className="min-w-0 rounded-[22px] border border-line bg-raised p-5 md:p-8">
          <div className="flex flex-wrap items-center justify-between gap-4">
            <p className="text-[15px] font-medium">Your Mac's memory</p>
            <div role="radiogroup" aria-label="Memory" className="flex rounded-full border border-line bg-sunken p-1">
              {memories.map((gb) => (
                <button
                  key={gb}
                  role="radio"
                  aria-checked={memory === gb}
                  onClick={() => setMemory(gb)}
                  className={`relative rounded-full px-3 py-1.5 text-[13px] font-medium tabular-nums transition-colors md:px-3.5 ${memory === gb ? "text-accent-ink" : "text-muted hover:text-ink"}`}
                >
                  {memory === gb && (
                    <motion.span layoutId="mem" transition={reduce ? { duration: 0 } : { type: "spring", stiffness: 420, damping: 34 }} className="absolute inset-0 rounded-full bg-accent" />
                  )}
                  <span className="relative">{gb} GB</span>
                </button>
              ))}
            </div>
          </div>

          <ul className="mt-8 space-y-3.5">
            {models.map((m) => {
              const f = fit(m.gb, memory);
              const chosen = pick?.name === m.name;
              return (
                <li key={m.name} className={`transition-opacity duration-300 ${f === "no" ? "opacity-40" : ""}`}>
                  <div className="mb-1.5 flex items-baseline justify-between gap-3 text-[14px]">
                    <span className={chosen ? "font-semibold text-ink" : "text-ink"}>
                      {m.name}
                      {chosen && <span className="ml-2 rounded-full bg-accent/15 px-2 py-0.5 text-[11.5px] font-semibold text-accent">Lizard picks</span>}
                    </span>
                    <span className="shrink-0 text-[12.5px] tabular-nums text-faint">
                      {m.gb.toFixed(1)} GB · {fitLabel[f]}
                    </span>
                  </div>
                  <div className="h-2 overflow-hidden rounded-full bg-sunken">
                    <motion.div
                      className={`h-full rounded-full ${f === "no" ? "bg-line-strong" : f === "tight" ? "bg-[#e0a43a]" : "bg-accent"}`}
                      initial={false}
                      animate={{ width: `${((m.gb * 1.15 + 1.5) / max) * 100}%` }}
                      transition={reduce ? { duration: 0 } : { duration: 0.6, ease: [0.16, 1, 0.3, 1] }}
                    />
                  </div>
                </li>
              );
            })}
          </ul>
          <p className="mt-8 text-[13px] leading-relaxed text-faint">
            Bars show memory in use while the model answers. Search by meaning indexes notes, work log, clipboard and screenshots on device too, with Apple's sentence embeddings or a small multilingual model.
          </p>
        </div>
      </div>
    </section>
  );
}
