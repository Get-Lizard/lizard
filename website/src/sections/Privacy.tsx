import { Cpu, FileText, LockKey } from "@phosphor-icons/react";

const points = [
  { icon: Cpu, title: "Local AI", body: "Apple Intelligence and models running on your Mac's GPU. Cloud AI is off until you switch it on." },
  { icon: FileText, title: "Plain files", body: "Notes and work logs are Markdown files in your folders. Open them with anything." },
  { icon: LockKey, title: "Keys stay put", body: "API keys live in the macOS Keychain. Copied passwords are never stored." },
];

/** Editorial statement over three columns. */
export function Privacy() {
  return (
    <section className="border-y border-line bg-sunken">
      <div className="mx-auto max-w-[1240px] px-4 py-28 md:px-8 md:py-36">
        <p className="max-w-[22ch] text-[40px] font-semibold leading-[1.08] tracking-[-0.03em] md:text-[64px]">
          Nothing leaves your Mac <span className="text-muted">unless you say so.</span>
        </p>
        <div className="mt-16 grid gap-10 md:grid-cols-3 md:gap-12">
          {points.map(({ icon: Icon, title, body }) => (
            <div key={title} className="border-t border-line-strong pt-6">
              <Icon size={26} weight="duotone" className="text-accent" />
              <h3 className="mt-4 text-lg font-semibold">{title}</h3>
              <p className="mt-2 text-[15px] leading-relaxed text-muted">{body}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
