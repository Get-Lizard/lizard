import { GithubLogo } from "@phosphor-icons/react";
import { InstallCommand } from "../Install";
import { Mark } from "../Mark";
import { REPO } from "./Nav";

/** The close: a manifesto-style centered moment (allowed for the final call to action). */
export function Closing() {
  return (
    <section className="relative overflow-hidden border-t border-line">
      <div aria-hidden className="pointer-events-none absolute left-1/2 top-1/2 h-[560px] w-[760px] -translate-x-1/2 -translate-y-1/2 rounded-full bg-[radial-gradient(closest-side,color-mix(in_oklab,var(--accent)_18%,transparent),transparent)] blur-2xl" />
      <div className="relative mx-auto flex max-w-[1240px] flex-col items-center px-4 py-32 text-center md:px-8 md:py-44">
        <Mark size={96} />
        <h2 className="mt-8 text-5xl font-semibold tracking-[-0.035em] md:text-7xl">Get Lizard.</h2>
        <p className="mt-5 max-w-[42ch] text-[17px] leading-relaxed text-muted">Free and open source. For macOS 26 on Apple Silicon, signed and notarized.</p>
        <div className="mt-10">
          <InstallCommand large />
        </div>
      </div>
      <footer className="mx-auto flex max-w-[1240px] flex-col gap-4 border-t border-line px-4 py-10 text-[14px] text-faint md:flex-row md:items-center md:justify-between md:px-8">
        <span className="flex items-center gap-2">
          <Mark size={18} animate={false} /> Lizard, MIT licensed
        </span>
        <span className="flex flex-wrap gap-6">
          <a className="hover:text-ink" href={`${REPO}/releases`}>Releases</a>
          <a className="hover:text-ink" href={`${REPO}/blob/main/docs/EXTENSIONS.md`}>Build an extension</a>
          <a className="inline-flex items-center gap-1.5 hover:text-ink" href={REPO}><GithubLogo size={15} weight="fill" /> GitHub</a>
        </span>
      </footer>
    </section>
  );
}
