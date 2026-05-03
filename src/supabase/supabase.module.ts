import { Global, Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { createClient } from '@supabase/supabase-js';
import { SUPABASE_CLIENT } from './supabase.constants';

@Global()
@Module({
  imports: [ConfigModule],
  providers: [
    {
      provide: SUPABASE_CLIENT,
      inject: [ConfigService],
      useFactory: (config: ConfigService) => {
        const url = config.getOrThrow<string>('SUPABASE_URL');
        const key = config.getOrThrow<string>('SUPABASE_PUBLISHABLE_KEY');
        return createClient(url, key);
      },
    },
  ],
  exports: [SUPABASE_CLIENT],
})
export class SupabaseModule {}
