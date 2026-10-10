// Google's free web translation endpoint (the one the translate.google.com widget uses).
export const LANGUAGES: Record<string, string> = {
  auto: "Detect", en: "English", pt: "Portuguese", es: "Spanish", fr: "French", de: "German", it: "Italian",
  nl: "Dutch", ja: "Japanese", "zh-CN": "Chinese (Simplified)", ko: "Korean", ru: "Russian", ar: "Arabic",
  hi: "Hindi", pl: "Polish", sv: "Swedish", tr: "Turkish", uk: "Ukrainian",
};

export interface Translation {
  text: string;
  detected: string;
}

export async function translate(text: string, target: string, source = "auto", signal?: AbortSignal): Promise<Translation> {
  const url = new URL("https://translate.googleapis.com/translate_a/single");
  url.search = new URLSearchParams({ client: "gtx", sl: source, tl: target, dt: "t", q: text }).toString();
  const response = await fetch(url, { signal });
  if (!response.ok) throw new Error(`Translation failed (${response.status})`);
  const body = (await response.json()) as [Array<[string, string]>, unknown, string];
  const translated = (body[0] ?? []).map((chunk) => chunk[0]).join("");
  return { text: translated, detected: body[2] ?? source };
}
