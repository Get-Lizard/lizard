import { GithubLogo } from "@phosphor-icons/react";

const steps = [
  {
    n: "01",
    title: "No CLI? Lizard fetches it.",
    body: "If GitHub's official gh CLI isn't on your Mac, Lizard downloads a private copy for itself. Your own install is used when you have one.",
  },
  {
    n: "02",
    title: "Approve in the browser.",
    body: "Lizard shows a one-time code and copies it. Paste it on github.com/login/device and you're in. No tokens to create.",
  },
  {
    n: "03",
    title: "Reviews in your menu bar.",
    body: "The GitHub Review Requests extension puts GitHub's mark in the menu bar with a count of pull requests waiting on you.",
  },
];

/** Centered statement, the device code as typography, and three numbered steps. */
export function GitHub() {
  return (
    <section id="github" className="mx-auto max-w-[1240px] px-4 py-28 md:px-8 md:py-36">
      <div className="mx-auto max-w-[760px] text-center">
        <GithubLogo size={44} weight="fill" className="mx-auto text-ink" />
        <h2 className="mt-7 text-4xl font-semibold leading-[1.05] tracking-[-0.03em] md:text-5xl">GitHub, signed in with one code.</h2>
        <p className="mx-auto mt-5 max-w-[52ch] text-[17px] leading-relaxed text-muted">
          Lizard talks to GitHub through the gh CLI, so sign-in is GitHub's own browser flow. The same login lets extensions install from private repos.
        </p>
        <div className="mx-auto mt-12 inline-flex items-center gap-3 rounded-2xl border border-line-strong bg-raised px-7 py-5 font-mono text-[30px] font-semibold tracking-[0.18em] text-ink md:text-[40px]">
          WDJB<span className="text-faint">-</span>MJHT
        </div>
        <p className="mt-3 text-[13px] text-faint">The code is on your clipboard. Paste it at github.com/login/device.</p>
      </div>

      <ol className="mt-20 grid gap-px overflow-hidden rounded-[22px] border border-line bg-line md:grid-cols-3">
        {steps.map((s) => (
          <li key={s.n} className="bg-bg p-7 md:p-9">
            <span className="font-mono text-[13px] text-accent">{s.n}</span>
            <h3 className="mt-4 text-lg font-semibold">{s.title}</h3>
            <p className="mt-2 text-[15px] leading-relaxed text-muted">{s.body}</p>
          </li>
        ))}
      </ol>
    </section>
  );
}
