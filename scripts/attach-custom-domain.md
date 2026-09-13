# Custom domain

Pages project `audiobook-binder` is on the Cloudflare account
`audio.reader.service@gmail.com` (id `90bb39de7b77f2ae18f92bcf667a13d2`).

The hostname `audiobook-binder.nwai.cc` is already attached to the project.
It stays **pending** until DNS exists.

`nwai.cc` nameservers are Cloudflare, but the **zone is not on this account**.
Add this record on the account that owns the zone (`myaudid@outlook.com` /
Arc Audio Reader):

```
Type   CNAME
Name   audiobook-binder
Target audiobook-binder.pages.dev
Proxy  DNS only or proxied
```

Until that lands, the site is at https://audiobook-binder.pages.dev
