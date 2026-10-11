const logos = [
  { slug: "github", name: "GitHub" },
  { slug: "slack", name: "Slack" },
  { slug: "1password", name: "1Password" },
  { slug: "linear", name: "Linear" },
  { slug: "warp", name: "Warp" },
  { slug: "googletranslate", name: "Google Translate" },
  { slug: "apple", name: "Apple Notes and Reminders" },
  { slug: "docker", name: "Docker" },
  { slug: "homebrew", name: "Homebrew" },
];

/** Split: the pitch and real commands on the left, a logo marquee (the page's only one) on the right. */
export function Extensions() {
  return (
    <section id="extensions" className="mx-auto grid max-w-[1240px] grid-cols-1 gap-14 px-4 py-28 md:px-8 md:py-36 lg:grid-cols-[1fr_1fr] lg:items-center">
      <div className="min-w-0">
        <h2 className="max-w-[16ch] text-4xl font-semibold leading-[1.05] tracking-[-0.03em] md:text-5xl">Extensions without a gatekeeper.</h2>
        <p className="mt-5 max-w-[50ch] text-[17px] leading-relaxed text-muted">
          Paste any GitHub repo link. Lizard runs Raycast extensions, checks for updates, and labels third-party code as External.
        </p>
        <pre className="mt-9 overflow-x-auto rounded-2xl border border-line bg-raised p-6 font-mono text-[13.5px] leading-7 text-muted">
<span className="text-faint"># build one (lizardcli comes with Lizard)</span>{"\n"}<span className="text-ink">lizardcli ext new</span> my-extension{"\n"}<span className="text-ink">lizardcli ext validate</span> my-extension{"\n"}{"\n"}<span className="text-faint"># share it</span>{"\n"}<span className="text-ink">git push</span>{"  "}<span className="text-faint"># install from github.com/you/my-extension</span>
        </pre>
      </div>

      <div className="relative min-w-0 overflow-hidden rounded-[22px] border border-line bg-raised py-16 [mask-image:linear-gradient(90deg,transparent,black_12%,black_88%,transparent)]">
        <div className="marquee-track flex w-max gap-14 px-7">
          {[...logos, ...logos].map((logo, i) => (
            <img
              key={`${logo.slug}-${i}`}
              src={`https://cdn.simpleicons.org/${logo.slug}/8a968f`}
              alt={i < logos.length ? logo.name : ""}
              aria-hidden={i >= logos.length}
              width={44}
              height={44}
              loading="lazy"
              className="h-11 w-11 opacity-80"
            />
          ))}
        </div>
        <p className="mt-12 px-8 text-[15px] leading-relaxed text-muted">
          Built-in extensions cover Translate, Slack, 1Password, Apple Notes, Reminders, Warp and more.
        </p>
      </div>
    </section>
  );
}
