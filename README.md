<p align="center">
  <a href="http://nestjs.com/" target="blank"><img src="https://nestjs.com/img/logo-small.svg" width="120" alt="Nest Logo" /></a>
</p>

[circleci-image]: https://img.shields.io/circleci/build/github/nestjs/nest/master?token=abc123def456
[circleci-url]: https://circleci.com/gh/nestjs/nest

  <p align="center">A progressive <a href="http://nodejs.org" target="_blank">Node.js</a> framework for building efficient and scalable server-side applications.</p>
    <p align="center">
<a href="https://www.npmjs.com/~nestjscore" target="_blank"><img src="https://img.shields.io/npm/v/@nestjs/core.svg" alt="NPM Version" /></a>
<a href="https://www.npmjs.com/~nestjscore" target="_blank"><img src="https://img.shields.io/npm/l/@nestjs/core.svg" alt="Package License" /></a>
<a href="https://www.npmjs.com/~nestjscore" target="_blank"><img src="https://img.shields.io/npm/dm/@nestjs/common.svg" alt="NPM Downloads" /></a>
<a href="https://circleci.com/gh/nestjs/nest" target="_blank"><img src="https://img.shields.io/circleci/build/github/nestjs/nest/master" alt="CircleCI" /></a>
<a href="https://discord.gg/G7Qnnhy" target="_blank"><img src="https://img.shields.io/badge/discord-online-brightgreen.svg" alt="Discord"/></a>
<a href="https://opencollective.com/nest#backer" target="_blank"><img src="https://opencollective.com/nest/backers/badge.svg" alt="Backers on Open Collective" /></a>
<a href="https://opencollective.com/nest#sponsor" target="_blank"><img src="https://opencollective.com/nest/sponsors/badge.svg" alt="Sponsors on Open Collective" /></a>
  <a href="https://paypal.me/kamilmysliwiec" target="_blank"><img src="https://img.shields.io/badge/Donate-PayPal-ff3f59.svg" alt="Donate us"/></a>
    <a href="https://opencollective.com/nest#sponsor"  target="_blank"><img src="https://img.shields.io/badge/Support%20us-Open%20Collective-41B883.svg" alt="Support us"></a>
  <a href="https://twitter.com/nestframework" target="_blank"><img src="https://img.shields.io/twitter/follow/nestframework.svg?style=social&label=Follow" alt="Follow us on Twitter"></a>
</p>
  <!--[![Backers on Open Collective](https://opencollective.com/nest/backers/badge.svg)](https://opencollective.com/nest#backer)
  [![Sponsors on Open Collective](https://opencollective.com/nest/sponsors/badge.svg)](https://opencollective.com/nest#sponsor)-->

## Description

Petlink backend: [Nest](https://github.com/nestjs/nest) API with [Supabase](https://supabase.com) (Postgres + Auth). Core schema migrations live under `supabase/migrations/`.

## Project setup

```bash
$ npm install
```

Copy environment variables and fill in values from the Supabase dashboard:

```bash
cp .env.example .env
```

Required for the Nest app: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` (anon/publishable client key). Add `SUPABASE_SERVICE_ROLE_KEY` for local tooling only (seed script below); keep it secret and never commit it.

The app exposes a global Supabase JS client via `SupabaseModule`. Inject it with `@Inject(SUPABASE_CLIENT)` and type `SupabaseClient` from `@supabase/supabase-js`.

## Supabase CLI and database migrations

Install the [Supabase CLI](https://supabase.com/docs/guides/cli) (or use the local devDependency via `npx supabase`).

Link this repo to your hosted project (project ref is the subdomain of `SUPABASE_URL`, e.g. `faoxxiwpvtbhadisdyfm`):

```bash
supabase login
supabase link --project-ref faoxxiwpvtbhadisdyfm
```

Apply migrations to the linked remote database:

```bash
npm run db:push
```

Migrations in `supabase/migrations/` run in timestamp order: core schema first (`*_petlink_core.sql`), then services/chat/notifications/FCM (`*_services_chat_notifications_fcm.sql`).

### Seed default Auth user (development)

With `SUPABASE_SERVICE_ROLE_KEY` set in `.env`, create a default user (password defaults to `petlink`) and upsert matching `public.profiles`:

```bash
npm run seed:default-user
```

Defaults: email `admin@petlink.local`, profile role `admin`. Override with `SEED_DEFAULT_USER_EMAIL`, `SEED_DEFAULT_USER_PASSWORD`, `SEED_DEFAULT_PROFILE_NAME`, and `SEED_DEFAULT_PROFILE_ROLE` (see `.env.example`).

To verify email/password login (same flow as a client app, using `SUPABASE_PUBLISHABLE_KEY`):

```bash
npm run test:auth-login
```

Optional env: `TEST_LOGIN_EMAIL`, `TEST_LOGIN_PASSWORD`. A successful run prints the user id and a truncated JWT (`access_token`).

Useful scripts: `db:migrate:new` (create an empty migration file), `db:diff`, `db:start` / `db:stop` (local stack via Docker), `seed:default-user`, `test:auth-login`.

After `db:push`, confirm in the SQL editor or `psql` that `public.profiles.id` has a foreign key to `auth.users(id)`, and that `clinic_profiles.open_days` only allows integers from 1 through 7 (1 = Monday, 7 = Sunday).

Row Level Security (RLS) policies and an `auth.users` trigger to auto-insert `public.profiles` are not included; add them in follow-up migrations when product rules are fixed.

## Compile and run the project

```bash
# development
$ npm run start

# watch mode
$ npm run start:dev

# production mode
$ npm run start:prod
```

## Run tests

```bash
# unit tests
$ npm run test

# e2e tests
$ npm run test:e2e

# test coverage
$ npm run test:cov
```

## Deployment

When you're ready to deploy your NestJS application to production, there are some key steps you can take to ensure it runs as efficiently as possible. Check out the [deployment documentation](https://docs.nestjs.com/deployment) for more information.

If you are looking for a cloud-based platform to deploy your NestJS application, check out [Mau](https://mau.nestjs.com), our official platform for deploying NestJS applications on AWS. Mau makes deployment straightforward and fast, requiring just a few simple steps:

```bash
$ npm install -g @nestjs/mau
$ mau deploy
```

With Mau, you can deploy your application in just a few clicks, allowing you to focus on building features rather than managing infrastructure.

## Resources

Check out a few resources that may come in handy when working with NestJS:

- Visit the [NestJS Documentation](https://docs.nestjs.com) to learn more about the framework.
- For questions and support, please visit our [Discord channel](https://discord.gg/G7Qnnhy).
- To dive deeper and get more hands-on experience, check out our official video [courses](https://courses.nestjs.com/).
- Deploy your application to AWS with the help of [NestJS Mau](https://mau.nestjs.com) in just a few clicks.
- Visualize your application graph and interact with the NestJS application in real-time using [NestJS Devtools](https://devtools.nestjs.com).
- Need help with your project (part-time to full-time)? Check out our official [enterprise support](https://enterprise.nestjs.com).
- To stay in the loop and get updates, follow us on [X](https://x.com/nestframework) and [LinkedIn](https://linkedin.com/company/nestjs).
- Looking for a job, or have a job to offer? Check out our official [Jobs board](https://jobs.nestjs.com).

## Support

Nest is an MIT-licensed open source project. It can grow thanks to the sponsors and support by the amazing backers. If you'd like to join them, please [read more here](https://docs.nestjs.com/support).

## Stay in touch

- Author - [Kamil Myśliwiec](https://twitter.com/kammysliwiec)
- Website - [https://nestjs.com](https://nestjs.com/)
- Twitter - [@nestframework](https://twitter.com/nestframework)

## License

Nest is [MIT licensed](https://github.com/nestjs/nest/blob/master/LICENSE).
