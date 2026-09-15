const albums = [
  { id: 'night-geometry', title: 'Night Geometry', artist: 'The Meridian Lines' },
  { id: 'glass-signals', title: 'Glass Signals', artist: 'Low Arc' },
  { id: 'last-train', title: 'After the Last Train', artist: 'June Harbor' },
  { id: 'soft-machines', title: 'Soft Machines', artist: 'Static Gardens' },
];

export default function Home() {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="mx-auto flex min-h-screen max-w-6xl flex-col px-5 py-8 sm:px-10 sm:py-12">
        <header className="flex items-center justify-between border-b border-white/10 pb-6">
          <div>
            <p className="eyebrow">Not Streaming</p>
            <p className="mt-1 text-sm text-muted-foreground">App Review demonstration service</p>
          </div>
          <div className="flex items-center gap-2 rounded-full border border-amber-400/25 bg-amber-400/8 px-3 py-2 text-sm text-amber-300">
            <span className="h-2 w-2 rounded-full bg-amber-300 shadow-[0_0_12px_rgba(252,211,77,.85)]" />
            Online
          </div>
        </header>

        <section className="grid flex-1 items-center gap-12 py-14 lg:grid-cols-[1.05fr_.95fr] lg:py-20">
          <div className="max-w-2xl">
            <p className="eyebrow">A private collection, simulated</p>
            <h1 className="mt-5 font-heading text-5xl font-semibold leading-[.98] tracking-[-.045em] sm:text-7xl">
              The CD changer,<br /><span className="text-amber-300">without the hardware.</span>
            </h1>
            <p className="mt-7 max-w-xl text-lg leading-8 text-muted-foreground">
              This isolated service lets App Review exercise the complete Not Streaming experience using fictional albums and simulated playback.
            </p>
            <div className="mt-9 grid max-w-xl gap-3 sm:grid-cols-3">
              {['No personal media', 'No home-network access', 'No real playback'].map((item) => (
                <div key={item} className="rounded-lg border border-white/10 bg-white/[.035] px-4 py-4 text-sm text-zinc-300">{item}</div>
              ))}
            </div>
          </div>

          <div className="machine-panel rounded-2xl p-5 sm:p-7">
            <div className="flex items-center justify-between border-b border-black/50 pb-5">
              <div>
                <p className="text-xs font-bold tracking-[.28em] text-zinc-400">DEMO LIBRARY</p>
                <p className="mt-1 font-mono text-xs text-amber-300">4 DISCS READY</p>
              </div>
              <div className="flex gap-1.5" aria-hidden="true">
                <span className="h-2 w-2 rounded-full bg-amber-300" />
                <span className="h-2 w-2 rounded-full bg-zinc-700" />
              </div>
            </div>
            <div className="mt-6 grid grid-cols-2 gap-4">
              {albums.map((album) => (
                <article key={album.title} className="group">
                  <img
                    src={`/covers/${album.id}.jpg`}
                    alt={`${album.title} by ${album.artist} album artwork`}
                    className="aspect-square w-full rounded-sm border border-white/10 object-cover shadow-lg transition-transform group-hover:-translate-y-1"
                  />
                  <p className="mt-2 text-sm font-medium text-zinc-200">{album.title}</p>
                  <p className="text-xs text-zinc-500">{album.artist}</p>
                </article>
              ))}
            </div>
          </div>
        </section>

        <footer className="flex flex-col gap-3 border-t border-white/10 pt-6 text-sm text-muted-foreground sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-center gap-4">
            <p>For evaluation of the Not Streaming iOS app.</p>
            <a className="text-amber-300 underline decoration-amber-300/35 underline-offset-4 hover:text-amber-200" href="/support">Support</a>
            <a className="text-amber-300 underline decoration-amber-300/35 underline-offset-4 hover:text-amber-200" href="/privacy">Privacy</a>
          </div>
          <p className="font-mono text-xs text-zinc-600">SIMULATION · NO AUDIO IS TRANSMITTED</p>
        </footer>
      </div>
    </main>
  );
}
