import { useEffect, useRef } from "react";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { useReducedMotion } from "motion/react";

gsap.registerPlugin(ScrollTrigger);

const slides = [
  {
    image: "./shots/meaning.webp",
    width: 1680, height: 1063,
    title: "Search by meaning.",
    body: "“payments were slow” finds the checkout incident note. None of those words are in it.",
    alt: "Searching “payments were slow” finds the note titled Checkout requests hanging",
  },
  {
    image: "./shots/ask.webp",
    width: 1680, height: 500,
    title: "Ask, and get sources.",
    body: "Answers come only from your notes, work log and screenshots, and point back to where they came from.",
    alt: "Ask Your Notes answering how the hanging checkout requests were fixed, citing the incident note",
  },
  {
    image: "./shots/notes.webp",
    width: 1680, height: 1063,
    title: "Notes that look finished while you type.",
    body: "Live Markdown, folders and tags. Code blocks get a copy button, so a command is one click away.",
    alt: "The notes editor with folders, tags, and a code block with a copy button",
  },
];

/** Pinned horizontal pan through real screens (storytelling: one AI capability per slide). */
export function AIPan() {
  const wrap = useRef<HTMLElement>(null);
  const track = useRef<HTMLDivElement>(null);
  const reduce = useReducedMotion();

  useEffect(() => {
    if (reduce || !wrap.current || !track.current) return;
    const mm = gsap.matchMedia();
    mm.add("(min-width: 1024px)", () => {
      const distance = () => track.current!.scrollWidth - window.innerWidth;
      const tween = gsap.to(track.current, {
        x: () => -distance(),
        ease: "none",
        scrollTrigger: {
          trigger: wrap.current,
          start: "top top",
          end: () => `+=${distance()}`,
          pin: true,
          scrub: 1,
          invalidateOnRefresh: true,
        },
      });
      return () => tween.kill();
    });
    return () => mm.revert();
  }, [reduce]);

  return (
    <section id="ai" ref={wrap} className="relative overflow-hidden border-t border-line bg-sunken">
      <div ref={track} className="flex flex-col gap-16 px-4 py-24 md:px-8 lg:h-[100dvh] lg:w-max lg:flex-row lg:items-center lg:gap-24 lg:px-[8vw] lg:py-0">
        <div className="max-w-[440px] shrink-0">
          <h2 className="text-4xl font-semibold leading-[1.05] tracking-[-0.03em] md:text-5xl">
            An AI that knows your notes, and stays on your Mac.
          </h2>
          <p className="mt-5 text-[17px] leading-relaxed text-muted">
            Apple Intelligence and local models do the reading. Nothing is uploaded unless you turn on a cloud AI.
          </p>
        </div>
        {slides.map((slide) => (
          <figure key={slide.title} className="w-full shrink-0 lg:w-[min(64vw,940px)]">
            <img src={slide.image} width={slide.width} height={slide.height} alt={slide.alt} loading="lazy" className="screen w-full" />
            <figcaption className="mt-6 max-w-[560px]">
              <span className="block text-2xl font-semibold tracking-[-0.02em]">{slide.title}</span>
              <span className="mt-2 block text-[16px] leading-relaxed text-muted">{slide.body}</span>
            </figcaption>
          </figure>
        ))}
      </div>
    </section>
  );
}
