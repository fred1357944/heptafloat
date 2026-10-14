// For running capture.sh / record-demo.sh on Linux: makes the editor treat ⌘ (Meta) as its Mod key.
Object.defineProperty(Navigator.prototype, 'platform', { get: () => 'MacIntel' });
