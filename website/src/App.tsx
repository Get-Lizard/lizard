import { Nav } from "./sections/Nav";
import { Hero } from "./sections/Hero";
import { AIPan } from "./sections/AIPan";
import { Bento } from "./sections/Bento";
import { LocalModels } from "./sections/LocalModels";
import { WorkLog } from "./sections/WorkLog";
import { GitHub } from "./sections/GitHub";
import { Travel } from "./sections/Travel";
import { Privacy } from "./sections/Privacy";
import { Extensions } from "./sections/Extensions";
import { Shortcuts } from "./sections/Shortcuts";
import { Closing } from "./sections/Closing";
import { Stats } from "./sections/Stats";
import { Showcase } from "./sections/Showcase";
import { SnippetsDemo } from "./sections/SnippetsDemo";
import { FirstRun } from "./sections/FirstRun";

export function App() {
  return (
    <div className="grain">
      <Nav />
      <main>
        <Hero />
        <Stats />
        <Showcase />
        <AIPan />
        <SnippetsDemo />
        <LocalModels />
        <Bento />
        <WorkLog />
        <GitHub />
        <FirstRun />
        <Privacy />
        <Extensions />
        <Travel />
        <Shortcuts />
        <Closing />
      </main>
    </div>
  );
}
