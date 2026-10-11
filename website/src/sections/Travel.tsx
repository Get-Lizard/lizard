import { ArrowsClockwise, Export, FileArchive, Package, Lightning } from "@phosphor-icons/react";

const rows = [
  {
    icon: Lightning,
    title: "Coming from Raycast",
    body: "Setup spots Raycast and lists the extensions you already use. They run in Lizard as they are, no rebuild. Quicklinks come across from Raycast's own export, placeholders and all.",
    detail: "Raycast encrypts each extension's saved data, so that part starts fresh.",
  },
  {
    icon: ArrowsClockwise,
    title: "Every Mac on your Apple Account",
    body: "Turn on iCloud sync and settings, shortcuts and quicklinks follow you. Extensions you installed from GitHub on one Mac are offered on the next. Notes and the work log can live in iCloud Drive too.",
    detail: "Uses your iCloud Drive. No Lizard account, no Lizard server.",
  },
];

const files = [
  { icon: Package, ext: ".lizardext", who: "For a friend", body: "One extension's source. No data, no preferences, nothing of yours." },
  { icon: FileArchive, ext: ".lizardbackup", who: "For you", body: "Settings, quicklinks, extensions with their data, and optionally notes and chats." },
];

/** Import, sync, share: two rows of prose and a two-file comparison. */
export function Travel() {
  return (
    <section id="sync" className="border-t border-line">
      <div className="mx-auto max-w-[1240px] px-4 py-28 md:px-8 md:py-36">
        <h2 className="max-w-[18ch] text-4xl font-semibold leading-[1.05] tracking-[-0.03em] md:text-5xl">Bring your setup. Take it anywhere.</h2>

        <div className="mt-16 divide-y divide-line border-y border-line">
          {rows.map(({ icon: Icon, title, body, detail }) => (
            <div key={title} className="grid gap-5 py-10 md:grid-cols-[280px_1fr] md:gap-12">
              <div className="flex items-center gap-3 md:items-start">
                <Icon size={24} weight="duotone" className="shrink-0 text-accent" />
                <h3 className="text-xl font-semibold">{title}</h3>
              </div>
              <div>
                <p className="max-w-[62ch] text-[17px] leading-relaxed text-muted">{body}</p>
                <p className="mt-3 text-[14px] text-faint">{detail}</p>
              </div>
            </div>
          ))}
          <div className="grid gap-5 py-10 md:grid-cols-[280px_1fr] md:gap-12">
            <div className="flex items-center gap-3 md:items-start">
              <Export size={24} weight="duotone" className="shrink-0 text-accent" />
              <h3 className="text-xl font-semibold">Sharing by file</h3>
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              {files.map(({ icon: Icon, ext, who, body }) => (
                <div key={ext} className="rounded-2xl border border-line bg-raised p-6">
                  <div className="flex items-center justify-between">
                    <Icon size={28} weight="duotone" className="text-accent" />
                    <span className="text-[12.5px] font-medium text-faint">{who}</span>
                  </div>
                  <p className="mt-5 font-mono text-[17px] text-ink">{ext}</p>
                  <p className="mt-2 text-[15px] leading-relaxed text-muted">{body}</p>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
