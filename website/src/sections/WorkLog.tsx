import { CalendarBlank, Medal, Sparkle } from "@phosphor-icons/react";
import { motion, useReducedMotion } from "motion/react";

const entries = [
  { time: "09:12", app: "Linear", text: "Took PAY-412 from triage" },
  { time: "11:40", app: "Xcode", text: "Fixed the flaky login test #ios" },
  { time: "14:03", app: "Terminal", text: "Cache pool to 50 #incident" },
  { time: "16:25", app: "Slack", text: "Payments rollout with Ana" },
];

const jobs = [
  { icon: Sparkle, title: "Summarize Today's Work", body: "A standup-ready paragraph from today's lines." },
  { icon: CalendarBlank, title: "Weekly Work Summary", body: "A status update for the last seven days." },
  { icon: Medal, title: "Performance Review", body: "Pick last quarter, this year or any dates. Lizard writes your self-review from the log." },
];

/** Split: how logging works on the left, the actual Markdown file filling in on the right. */
export function WorkLog() {
  const reduce = useReducedMotion();
  return (
    <section id="worklog" className="border-y border-line bg-sunken">
      <div className="mx-auto grid grid-cols-1 max-w-[1240px] gap-14 px-4 py-28 md:px-8 md:py-36 lg:grid-cols-[1fr_1.05fr] lg:items-center lg:gap-20">
        <div className="min-w-0">
          <h2 className="max-w-[15ch] text-4xl font-semibold leading-[1.05] tracking-[-0.03em] md:text-5xl">Remember what you did this week.</h2>
          <p className="mt-5 max-w-[48ch] text-[17px] leading-relaxed text-muted">
            Press <span className="kbd">⌥</span> <span className="kbd">⇧</span> <span className="kbd">W</span> anywhere, type one line, hit Return. Lizard stamps the time and the app you were in, tags it on device, and files it in this month's Markdown log. Forgot something? One click on Yesterday or Earlier, or <span className="kbd">⌘</span> <span className="kbd">[</span> to step back a day, and it lands in the right place.
          </p>
          <ul className="mt-12 divide-y divide-line border-y border-line">
            {jobs.map(({ icon: Icon, title, body }) => (
              <li key={title} className="flex items-start gap-4 py-5">
                <Icon size={22} weight="duotone" className="mt-0.5 shrink-0 text-accent" />
                <div>
                  <p className="font-semibold">{title}</p>
                  <p className="mt-1 text-[15px] text-muted">{body}</p>
                </div>
              </li>
            ))}
          </ul>
        </div>

        <figure className="min-w-0 overflow-hidden rounded-[22px] border border-line bg-raised">
          <figcaption className="flex items-center justify-between border-b border-line px-5 py-3.5 font-mono text-[12.5px] text-faint">
            <span>~/Documents/WorkLogs/2026-10.md</span>
            <span>Markdown</span>
          </figcaption>
          <div className="p-5 font-mono text-[13px] leading-7 md:p-7 md:text-[13.5px]">
            <p className="text-ink"># Work Log: October 2026</p>
            <p>&nbsp;</p>
            {entries.map((e, i) => (
              <motion.p
                key={e.time}
                className="-indent-[2ch] pl-[2ch] text-muted"
                initial={reduce ? false : { opacity: 0, x: -10 }}
                whileInView={{ opacity: 1, x: 0 }}
                viewport={{ once: true, margin: "-80px" }}
                transition={{ delay: 0.2 + i * 0.22, duration: 0.5, ease: [0.16, 1, 0.3, 1] }}
              >
                <span className="text-faint">- 2026-10-09T{e.time}</span> <span className="text-accent">[{e.app}]</span>{" "}
                {e.text.split(/(#\w+)/).map((part, j) => (part.startsWith("#") ? <span key={j} className="text-accent-deep">{part}</span> : part))}
              </motion.p>
            ))}
            <p className="mt-1 text-ink">
              - <span className="caret" aria-hidden />
            </p>
          </div>
        </figure>
      </div>
    </section>
  );
}
