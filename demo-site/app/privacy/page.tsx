import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Privacy Policy — Not Streaming',
  description: 'Privacy policy for the Not Streaming iOS app.',
};

const sectionClass = 'border-t border-white/10 pt-8';
const headingClass = 'font-heading text-2xl text-zinc-100';
const copyClass = 'mt-4 space-y-4 text-base leading-7 text-muted-foreground';

export default function PrivacyPolicy() {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="mx-auto flex min-h-screen max-w-3xl flex-col px-5 py-8 sm:px-10 sm:py-12">
        <header className="flex items-center justify-between border-b border-white/10 pb-6">
          <a className="eyebrow hover:text-amber-200" href="/">Not Streaming</a>
          <span className="font-mono text-xs tracking-[.16em] text-zinc-500">PRIVACY POLICY</span>
        </header>

        <article className="flex-1 space-y-10 py-14 sm:py-20">
          <div>
            <p className="eyebrow">Effective September 9, 2026</p>
            <h1 className="mt-5 font-heading text-5xl font-semibold tracking-[-.04em] sm:text-6xl">Privacy Policy</h1>
            <p className="mt-6 max-w-2xl text-lg leading-8 text-muted-foreground">
              Not Streaming is designed to control a music library on a system you configure. It does not require an account and does not use advertising, analytics, or tracking technologies.
            </p>
          </div>

          <section className={sectionClass}>
            <h2 className={headingClass}>Information we collect</h2>
            <div className={copyClass}>
              <p>Not Streaming does not collect or store your name, email address, contacts, location, music library, advertising identifiers, or other personal information through the app.</p>
              <p>Preferences such as the server address, Demo Mode setting, and library display choices are stored on your device.</p>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className={headingClass}>Your personal music library</h2>
            <div className={copyClass}>
              <p>When you connect Not Streaming to your own system, the app communicates with the companion server address you provide. Album information, queue status, and playback commands pass between your device and that server.</p>
              <p>The developer does not receive your music, music-library contents, server address, or playback activity. Your music remains on the systems you control.</p>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className={headingClass}>Demo Mode</h2>
            <div className={copyClass}>
              <p>Demo Mode connects to the Not Streaming demonstration service to provide fictional albums and simulated playback. It does not upload or play your personal music.</p>
              <p>The service uses a temporary session cookie containing simulated player state, such as loaded fictional discs, volume, and playback status. The cookie expires after 24 hours and is not used for advertising or tracking. Hosting infrastructure may process standard network information needed to deliver and protect the service.</p>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className={headingClass}>Support communications</h2>
            <div className={copyClass}>
              <p>If you email support, we receive your email address and anything you choose to include in your message. We use that information only to respond to your request and maintain necessary support records. We do not sell it or use it for advertising.</p>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className={headingClass}>Sharing and tracking</h2>
            <div className={copyClass}>
              <p>Not Streaming does not sell personal information, show advertisements, build user profiles, or track activity across apps or websites. The app contains no advertising or analytics SDKs.</p>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className={headingClass}>Changes to this policy</h2>
            <div className={copyClass}>
              <p>If the app’s privacy practices change, this policy will be updated and the effective date above will be revised.</p>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className={headingClass}>Contact</h2>
            <div className={copyClass}>
              <p>Questions about this policy may be sent to <a className="text-amber-300 underline decoration-amber-300/35 underline-offset-4 hover:text-amber-200" href="mailto:dev@cybersand.com">dev@cybersand.com</a>.</p>
            </div>
          </section>
        </article>

        <footer className="flex flex-col gap-2 border-t border-white/10 pt-6 text-sm text-muted-foreground sm:flex-row sm:items-center sm:justify-between">
          <p>© 2026 David Bret Sanders</p>
          <div className="flex gap-4">
            <a className="text-amber-300 hover:text-amber-200" href="/support">Support</a>
            <a className="text-amber-300 hover:text-amber-200" href="/">Return to demo</a>
          </div>
        </footer>
      </div>
    </main>
  );
}
