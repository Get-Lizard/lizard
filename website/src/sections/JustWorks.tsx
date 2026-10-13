import { ArrowsClockwise, Command, Heartbeat, Lightning } from "@phosphor-icons/react";
import { motion } from "motion/react";

const points = [
  {
    icon: ArrowsClockwise,
    title: "Updates itself",
    body: "Lizard checks for new versions once a day. One click installs it, through Homebrew or a download it verifies was signed by Lizard's developer and notarized by Apple.",
  },
  {
    icon: Heartbeat,
    title: "Gets back up",
    body: "If something ever goes wrong, Lizard restarts itself in a couple of seconds and tells you. Quitting it on purpose keeps it quit.",
  },
  {
    icon: Command,
    title: "⌘ Space, no fight",
    body: "Pick ⌘ Space in setup and Lizard moves Spotlight's shortcut aside. If Spotlight takes it back, Lizard notices and lets you choose.",
  },
  {
    icon: Lightning,
    title: "Always ready",
    body: "Opens at login and appears in a few milliseconds, with the field ready for typing. Your settings and data stay put across updates.",
  },
];

/** The quiet details: updates, recovery, the shortcut, speed. */
export function JustWorks() {
  return (
    <section className="mx-auto max-w-[1240px] px-4 py-28 md:px-8 md:py-36">
      <h2 className="max-w-[16ch] text-4xl font-semibold leading-[1.05] tracking-[-0.03em] md:text-5xl">Built to just work.</h2>
      <p className="mt-5 max-w-[52ch] text-[17px] leading-relaxed text-muted">The parts you only notice when other apps get them wrong.</p>
      <div className="mt-14 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {points.map(({ icon: Icon, title, body }, i) => (
          <motion.div
            key={title}
            initial={{ opacity: 0, y: 24 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, amount: 0.3 }}
            transition={{ delay: i * 0.08, duration: 0.6, ease: [0.16, 1, 0.3, 1] }}
            className="rounded-[22px] border border-line bg-raised p-7"
          >
            <span className="grid h-11 w-11 place-items-center rounded-xl border border-accent/40 bg-accent/10 text-accent">
              <Icon size={22} weight="duotone" />
            </span>
            <h3 className="mt-5 text-lg font-semibold">{title}</h3>
            <p className="mt-2 text-[15px] leading-relaxed text-muted">{body}</p>
          </motion.div>
        ))}
      </div>
    </section>
  );
}
