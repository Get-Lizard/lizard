import { ArrowUpRight, Globe, GithubLogo } from "@phosphor-icons/react";
import { DownloadButton, InstallCommand, Requirements } from "../Install";
import { Mark } from "../Mark";
import { REPO } from "./Nav";

/** The close: a manifesto-style centered moment (allowed for the final call to action). */
export function Closing() {
  return (
    <section className="relative overflow-hidden border-t border-line">
      <div aria-hidden className="pointer-events-none absolute left-1/2 top-1/2 h-[560px] w-[760px] -translate-x-1/2 -translate-y-1/2 rounded-full bg-[radial-gradient(closest-side,color-mix(in_oklab,var(--accent)_18%,transparent),transparent)] blur-2xl" />
      <div className="relative mx-auto flex max-w-[1240px] flex-col items-center px-4 pb-20 pt-32 text-center md:px-8 md:pb-24 md:pt-44">
        <Mark size={96} />
        <h2 className="mt-8 text-5xl font-semibold tracking-[-0.035em] md:text-7xl">Get Lizard.</h2>
        <p className="mt-5 max-w-[42ch] text-[17px] leading-relaxed text-muted">Free and open source, signed and notarized by Apple.</p>
        <div className="mt-10 flex flex-col items-center gap-4">
          <DownloadButton large />
          <span className="text-[14px] text-faint">or with Homebrew</span>
          <InstallCommand large />
          <Requirements center />
          <a href={`${REPO}/releases`} className="text-[14px] text-muted underline decoration-line-strong underline-offset-4 hover:text-ink">
            All releases and notes
          </a>
        </div>
      </div>
      <Maker />
      <footer className="mx-auto flex max-w-[1240px] flex-col gap-4 border-t border-line px-4 py-10 text-[14px] text-faint md:flex-row md:items-center md:justify-between md:px-8">
        <span className="flex items-center gap-2">
          <Mark size={18} animate={false} /> Lizard, MIT licensed. Made by <a className="text-muted hover:text-ink" href={MAKER_SITE}>Vitor Águila</a>
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

const MAKER_SITE = "https://vitoraguila.com/";
const MAKER_GITHUB = "https://github.com/vitoraguila";

/** Who builds Lizard: one engineer, with links to his site and GitHub. */
function Maker() {
  return (
    <div id="maker" className="relative mx-auto max-w-[1240px] scroll-mt-24 px-4 pb-16 md:px-8">
      <div className="mx-auto flex max-w-[720px] flex-col items-center gap-6 rounded-3xl border border-line bg-raised/70 p-6 text-center sm:flex-row sm:items-center sm:p-8 sm:text-left">
        <img
          src={`${MAKER_GITHUB}.png?size=160`}
          alt="Vitor Águila"
          width={80}
          height={80}
          loading="lazy"
          className="h-20 w-20 shrink-0 rounded-full border border-line object-cover"
        />
        <div className="flex flex-col gap-3">
          <p className="text-[12.5px] font-semibold uppercase tracking-[0.12em] text-accent">The engineer behind Lizard</p>
          <p className="text-[15.5px] leading-relaxed text-muted">
            Hi, I'm <strong className="font-semibold text-ink">Vitor Águila</strong>, a senior software engineer with 12+ years of building backends,
            products and AI integrations. Lizard is the launcher I wanted on my own Mac: native, fast, and private by default. I design it, build it and ship every release.
          </p>
          <span className="flex flex-wrap justify-center gap-x-5 gap-y-2 text-[14px] sm:justify-start">
            <a className="group inline-flex items-center gap-1.5 text-ink hover:text-accent" href={MAKER_SITE}>
              <Globe size={15} weight="bold" /> vitoraguila.com
              <ArrowUpRight size={13} className="opacity-60 transition-transform group-hover:-translate-y-0.5 group-hover:translate-x-0.5" />
            </a>
            <a className="group inline-flex items-center gap-1.5 text-ink hover:text-accent" href={MAKER_GITHUB}>
              <GithubLogo size={15} weight="fill" /> @vitoraguila
              <ArrowUpRight size={13} className="opacity-60 transition-transform group-hover:-translate-y-0.5 group-hover:translate-x-0.5" />
            </a>
          </span>
        </div>
      </div>
    </div>
  );
}
