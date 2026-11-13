// Service worker do acompanhamento no celular. Só cuida do aviso em segundo
// plano: nada é guardado em cache, para a página nunca ficar desatualizada.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('push', (e) => {
    let d = {};
    try { d = e.data ? e.data.json() : {}; } catch { /* aviso sem dados */ }
    const title = d.title || 'É a sua vez!';
    e.waitUntil(self.registration.showNotification(title, {
        body: d.body || 'Dirija-se ao atendimento.',
        icon: 'icon.svg',
        badge: 'icon.svg',
        tag: d.tag || 'senha',
        renotify: true,
        vibrate: [300, 150, 300, 150, 600],
        requireInteraction: true,
        data: { url: d.url || './' },
    }));
});

self.addEventListener('notificationclick', (e) => {
    e.notification.close();
    const url = new URL(e.notification.data?.url || './', self.location.href).href;
    e.waitUntil((async () => {
        const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
        for (const c of all) {
            if (c.url === url) return c.focus();
        }
        return self.clients.openWindow(url);
    })());
});
