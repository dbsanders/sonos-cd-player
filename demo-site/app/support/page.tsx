import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Support — Not Streaming',
  description: 'Contact information and help for the Not Streaming iOS app.',
};

export default function Support() {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="mx-auto flex min-h-screen max-w-3xl flex-col px-5 py-8 sm:px-10 sm:py-12">
        <header className="flex items-center justify-between border-b border-white/10 pb-6">
          <a className="eyebrow hover:text-amber-200" href="/">Not Streaming</a>
          <span className="font-mono text-xs tracking-[.16em] text-zinc-500">APP SUPPORT</span>
        </header>

        <section className="flex-1 py-14 sm:py-20">
          <p className="eyebrow">We’re here to help</p>
          <h1 className="mt-5 font-heading text-5xl font-semibold tracking-[-.04em] sm:text-6xl">Not Streaming support</h1>
          <p className="mt-6 max-w-2xl text-lg leading-8 text-muted-foreground">
            For help with setup, connection problems, playback controls, feedback, or feature requests, contact us by email.
          </p>

          <div className="machine-panel mt-10 rounded-2xl p-6 sm:p-8">
            <p className="text-sm font-medium text-zinc-400">SUPPORT EMAIL</p>
            <a
              className="mt-3 inline-block break-all font-heading text-3xl text-amber-300 underline decoration-amber-300/30 underline-offset-8 hover:text-amber-200 sm:text-4xl"
              href="mailto:dev@cybersand.com"
            >
              dev@cybersand.com
            </a>
          </div>

          <div className="mt-10 border-t border-white/10 pt-8">
            <h2 className="font-heading text-2xl">Connection checklist</h2>
            <ul className="mt-4 space-y-3 pl-5 text-base leading-7 text-muted-foreground marker:text-amber-300">
              <li>Demo Mode requires an internet connection and uses simulated playback.</li>
              <li>Your personal library requires the companion server and your iPhone or iPad to be on the same local network.</li>
              <li>If your library cannot connect, confirm the server address in Connection settings and allow Local Network access for Not Streaming.</li>
            </ul>
          </div>
        </section>

        <footer className="flex flex-col gap-2 border-t border-white/10 pt-6 text-sm text-muted-foreground sm:flex-row sm:items-center sm:justify-between">
          <p>© 2026 David Bret Sanders</p>
          <div className="flex gap-4">
            <a className="text-amber-300 hover:text-amber-200" href="/privacy">Privacy</a>
            <a className="text-amber-300 hover:text-amber-200" href="/">Return to demo</a>
          </div>
        </footer>
      </div>
    </main>
  );
}
