import { Nav } from "./sections/Nav";
import { Hero } from "./sections/Hero";
import { AIPan } from "./sections/AIPan";
import { Bento } from "./sections/Bento";
import { Privacy } from "./sections/Privacy";
import { Extensions } from "./sections/Extensions";
import { Shortcuts } from "./sections/Shortcuts";
import { Closing } from "./sections/Closing";

export function App() {
  return (
    <div className="grain">
      <Nav />
      <main>
        <Hero />
        <AIPan />
        <Bento />
        <Privacy />
        <Extensions />
        <Shortcuts />
        <Closing />
      </main>
    </div>
  );
}
