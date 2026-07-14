# luci-app-dae dashboard

The dashboard is a Vue 3 application compiled into LuCI static assets.
OpenWrt package builds consume the committed files under
`luci-app-dae/root/www/luci-static/resources/dae/dashboard/` and do not need
Node.js.

## Development

```sh
npm install
npm run dev
```

The development server only serves the frontend. API requests still target the
LuCI endpoint at `/cgi-bin/luci/admin/services/dae/api`.

## Production build

```sh
npm install
npm run build
```

Commit the regenerated dashboard assets together with frontend source changes.
