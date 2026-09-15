type Album = { id: string; title: string; artist: string; tracks: number };
type SavedSet = { id: string; name: string; albumIds: string[] };
type DemoState = {
  discIds: string[];
  currentDiscId: string | null;
  playing: boolean;
  volume: number;
  trackNumber: number;
  sets: SavedSet[];
};

const albums: Album[] = [
  { id: 'night-geometry', title: 'Night Geometry', artist: 'The Meridian Lines', tracks: 9 },
  { id: 'glass-signals', title: 'Glass Signals', artist: 'Low Arc', tracks: 11 },
  { id: 'last-train', title: 'After the Last Train', artist: 'June Harbor', tracks: 8 },
  { id: 'soft-machines', title: 'Soft Machines', artist: 'Static Gardens', tracks: 10 },
  { id: 'copper-sky', title: 'Under a Copper Sky', artist: 'North Window', tracks: 12 },
  { id: 'small-hours', title: 'The Small Hours', artist: 'Blue Assembly', tracks: 7 },
  { id: 'paper-moons', title: 'Paper Moons', artist: 'Hollow Cinema', tracks: 10 },
  { id: 'still-water', title: 'Still Water Maps', artist: 'Mara Vale', tracks: 9 },
];

const initialState = (): DemoState => ({
  discIds: ['night-geometry', 'glass-signals'],
  currentDiscId: 'night-geometry',
  playing: false,
  volume: 38,
  trackNumber: 1,
  sets: [{ id: 'evening-set', name: 'Evening set', albumIds: ['night-geometry', 'glass-signals', 'still-water'] }],
});

function encodeState(state: DemoState) {
  const bytes = new TextEncoder().encode(JSON.stringify(state));
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

function decodeState(request: Request): DemoState {
  const raw = request.headers.get('cookie')?.match(/(?:^|;\s*)ns_demo=([^;]+)/)?.[1];
  if (!raw) return initialState();
  try {
    const padded = raw.replaceAll('-', '+').replaceAll('_', '/') + '==='.slice((raw.length + 3) % 4);
    const bytes = Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
    return { ...initialState(), ...(JSON.parse(new TextDecoder().decode(bytes)) as DemoState) };
  } catch {
    return initialState();
  }
}

function json(request: Request, state: DemoState, body: unknown, status = 200) {
  const secure = new URL(request.url).protocol === 'https:' ? '; Secure' : '';
  return Response.json(body, {
    status,
    headers: {
      'cache-control': 'no-store',
      'set-cookie': `ns_demo=${encodeState(state)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=86400${secure}`,
    },
  });
}

function selectedAlbum(state: DemoState) {
  return albums.find((album) => album.id === state.currentDiscId) ?? null;
}

function albumPayload(album: Album, origin: string) {
  return {
    title: album.title,
    artist: album.artist,
    album_art_uri: `${origin}/covers/${album.id}.jpg`,
    uri: `demo:album:${album.id}`,
  };
}

function discPayload(state: DemoState) {
  let queueStart = 1;
  return state.discIds.flatMap((id) => {
    const album = albums.find((item) => item.id === id);
    if (!album) return [];
    const disc = { id: album.id, album: album.title, artist: album.artist, queue_start: queueStart, queue_end: queueStart + album.tracks - 1, tracks_added: album.tracks };
    queueStart += album.tracks;
    return [disc];
  });
}

function findAlbum(url: URL) {
  const title = url.searchParams.get('title') ?? '';
  const artist = url.searchParams.get('artist') ?? '';
  return albums.find((album) => album.title.localeCompare(title, undefined, { sensitivity: 'base' }) === 0 && (!artist || album.artist.localeCompare(artist, undefined, { sensitivity: 'base' }) === 0));
}

function pathPieces(request: Request) {
  return new URL(request.url).pathname.replace(/^\/api\/?/, '').split('/').filter(Boolean);
}

async function handle(request: Request) {
  const url = new URL(request.url);
  const path = pathPieces(request);
  const state = decodeState(request);
  const method = request.method;

  if (method === 'GET' && path[0] === 'albums') {
    return json(request, state, { albums: albums.map((album) => albumPayload(album, url.origin)) });
  }

  if (method === 'GET' && path[0] === 'status') {
    const album = selectedAlbum(state);
    return json(request, state, {
      track: album ? { title: `Track ${state.trackNumber}`, artist: album.artist, album: album.title, uri: `demo:track:${album.id}:${state.trackNumber}`, position: '0:01:42' } : {},
      transport: { current_transport_state: album ? (state.playing ? 'PLAYING' : 'PAUSED_PLAYBACK') : 'STOPPED' },
      volume: state.volume,
      muted: false,
    });
  }

  if (method === 'GET' && path[0] === 'discs') {
    const discs = discPayload(state);
    return json(request, state, { discs, current_disc_id: state.currentDiscId, queue_size: discs.reduce((sum, disc) => sum + disc.tracks_added, 0) });
  }

  if (method === 'GET' && path[0] === 'cd-sets') {
    return json(request, state, { sets: state.sets.map((set) => ({ id: set.id, name: set.name, albums: set.albumIds.flatMap((id) => { const album = albums.find((item) => item.id === id); return album ? [{ title: album.title, artist: album.artist }] : []; }) })) });
  }

  if (method === 'POST' && (path[0] === 'play-album' || (path[0] === 'discs' && path[1] === 'load'))) {
    const album = findAlbum(url);
    if (!album) return json(request, state, { detail: 'That demonstration album was not found.' }, 404);
    if (!state.discIds.includes(album.id)) state.discIds.push(album.id);
    if (path[0] === 'play-album') { state.currentDiscId = album.id; state.playing = true; state.trackNumber = 1; }
    return json(request, state, { ok: true });
  }

  if (path[0] === 'discs' && path.length === 1 && method === 'DELETE') {
    state.discIds = []; state.currentDiscId = null; state.playing = false; state.trackNumber = 1;
    return json(request, state, { ok: true });
  }

  if (path[0] === 'discs' && path[1] === 'shuffle' && method === 'POST') {
    state.discIds.reverse(); state.currentDiscId = state.discIds[0] ?? null; state.playing = state.discIds.length > 0; state.trackNumber = 1;
    return json(request, state, { ok: true });
  }

  if (path[0] === 'discs' && path[1] === 'resync' && method === 'POST') {
    state.discIds = []; state.currentDiscId = null; state.playing = false;
    return json(request, state, { ok: true });
  }

  if (path[0] === 'discs' && ['previous', 'next'].includes(path[1] ?? '') && method === 'POST') {
    const current = Math.max(0, state.discIds.indexOf(state.currentDiscId ?? ''));
    const offset = path[1] === 'next' ? 1 : -1;
    if (state.discIds.length) state.currentDiscId = state.discIds[(current + offset + state.discIds.length) % state.discIds.length];
    state.trackNumber = 1; state.playing = true;
    return json(request, state, { ok: true });
  }

  if (path[0] === 'discs' && path[1] && path[2] === 'play' && method === 'POST') {
    if (!state.discIds.includes(path[1])) return json(request, state, { detail: 'Disc is not loaded.' }, 404);
    state.currentDiscId = path[1]; state.trackNumber = 1; state.playing = true;
    return json(request, state, { ok: true });
  }

  if (path[0] === 'discs' && path[1] && path.length === 2 && method === 'DELETE') {
    state.discIds = state.discIds.filter((id) => id !== path[1]);
    if (state.currentDiscId === path[1]) state.currentDiscId = state.discIds[0] ?? null;
    if (!state.currentDiscId) state.playing = false;
    return json(request, state, { ok: true });
  }

  if (path[0] === 'tracks' && ['previous', 'next'].includes(path[1] ?? '') && method === 'POST') {
    const album = selectedAlbum(state);
    if (album) state.trackNumber = Math.min(album.tracks, Math.max(1, state.trackNumber + (path[1] === 'next' ? 1 : -1)));
    state.playing = Boolean(album);
    return json(request, state, { ok: true });
  }

  if (path[0] === 'play' && method === 'POST') { state.playing = Boolean(state.currentDiscId); return json(request, state, { ok: true }); }
  if (path[0] === 'pause' && method === 'POST') { state.playing = false; return json(request, state, { ok: true }); }
  if (path[0] === 'volume' && method === 'POST') { state.volume = Math.min(100, Math.max(0, Number(url.searchParams.get('level')) || 0)); return json(request, state, { ok: true }); }

  if (path[0] === 'cd-sets' && path.length === 1 && method === 'POST') {
    const name = (url.searchParams.get('name') ?? 'New set').slice(0, 80);
    if (state.sets.some((set) => set.name.localeCompare(name, undefined, { sensitivity: 'base' }) === 0)) {
      return json(request, state, { detail: 'A CD Set with that name already exists' }, 409);
    }
    const selected = url.searchParams.has('title') ? findAlbum(url) : null;
    if (url.searchParams.has('title') && !selected) {
      return json(request, state, { detail: 'That demonstration album was not found.' }, 404);
    }
    state.sets.push({ id: crypto.randomUUID(), name, albumIds: selected ? [selected.id] : [...state.discIds] });
    return json(request, state, { ok: true });
  }

  if (path[0] === 'cd-sets' && path[1] && path[2] === 'albums' && method === 'POST') {
    const set = state.sets.find((item) => item.id === path[1]);
    if (!set) return json(request, state, { detail: 'CD set not found.' }, 404);
    const album = findAlbum(url);
    if (!album) return json(request, state, { detail: 'That demonstration album was not found.' }, 404);
    if (set.albumIds.includes(album.id)) return json(request, state, { detail: `${album.title} is already in ${set.name}` }, 409);
    set.albumIds.push(album.id);
    return json(request, state, { ok: true });
  }

  if (path[0] === 'cd-sets' && path[1] && path.length === 2 && method === 'PUT') {
    const set = state.sets.find((item) => item.id === path[1]);
    if (!set) return json(request, state, { detail: 'CD set not found.' }, 404);
    set.albumIds = [...state.discIds];
    return json(request, state, { ok: true });
  }

  if (path[0] === 'cd-sets' && path[1] && path.length === 2 && method === 'DELETE') {
    state.sets = state.sets.filter((set) => set.id !== path[1]);
    return json(request, state, { ok: true });
  }

  if (path[0] === 'cd-sets' && path[1] && path[2] === 'play' && method === 'POST') {
    const set = state.sets.find((item) => item.id === path[1]);
    if (!set) return json(request, state, { detail: 'CD set not found.' }, 404);
    state.discIds = [...set.albumIds];
    if (url.searchParams.get('shuffle') === 'true') state.discIds.reverse();
    state.currentDiscId = state.discIds[0] ?? null; state.trackNumber = 1; state.playing = Boolean(state.currentDiscId);
    return json(request, state, { ok: true });
  }

  return json(request, state, { detail: 'Demo endpoint not found.' }, 404);
}

export const GET = handle;
export const POST = handle;
export const PUT = handle;
export const DELETE = handle;
