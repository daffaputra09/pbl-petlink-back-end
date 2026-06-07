import {
  Injectable,
  Logger,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import * as admin from 'firebase-admin';

export type ChatMessageRecord = {
  id: string;
  thread_id: string;
  sender_id: string;
  message_type: 'text' | 'image';
  message: string | null;
  attachment_url: string | null;
};

@Injectable()
export class ChatPushService {
  private readonly logger = new Logger(ChatPushService.name);
  private adminClient: SupabaseClient | null = null;
  private firebaseReady = false;

  constructor(private readonly config: ConfigService) {
    this.initFirebase();
  }

  private getAdminClient(): SupabaseClient | null {
    if (this.adminClient) return this.adminClient;

    const url = this.config.get<string>('SUPABASE_URL');
    const serviceKey = this.config.get<string>('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !serviceKey) {
      this.logger.warn('SUPABASE_SERVICE_ROLE_KEY missing — chat push disabled.');
      return null;
    }

    this.adminClient = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    return this.adminClient;
  }

  private initFirebase() {
    const raw = this.config.get<string>('FIREBASE_SERVICE_ACCOUNT_JSON');
    if (!raw?.trim()) {
      this.logger.warn(
        'FIREBASE_SERVICE_ACCOUNT_JSON not set — chat push disabled.',
      );
      return;
    }

    try {
      const credential = admin.credential.cert(JSON.parse(raw));
      if (!admin.apps.length) {
        admin.initializeApp({ credential });
      }
      this.firebaseReady = true;
    } catch (error) {
      this.logger.error('Failed to initialize Firebase Admin', error);
    }
  }

  verifyWebhookSecret(headerSecret?: string) {
    const expected = this.config.get<string>('CHAT_WEBHOOK_SECRET');
    if (!expected || headerSecret !== expected) {
      throw new UnauthorizedException('Invalid webhook secret');
    }
  }

  async sendForMessage(record: ChatMessageRecord) {
    if (!this.firebaseReady) {
      this.logger.warn('Skipping push — Firebase not configured.');
      return { sent: 0, skipped: true };
    }

    const adminClient = this.getAdminClient();
    if (!adminClient) {
      return { sent: 0, skipped: true };
    }

    const { data: thread, error: threadError } = await adminClient
      .from('chat_threads')
      .select('id, user_1_id, user_2_id')
      .eq('id', record.thread_id)
      .maybeSingle();

    if (threadError || !thread) {
      this.logger.warn(`Thread not found: ${record.thread_id}`);
      return { sent: 0 };
    }

    const recipientId =
      thread.user_1_id === record.sender_id
        ? thread.user_2_id
        : thread.user_1_id;

    const { data: sender } = await adminClient
      .from('profiles')
      .select('name')
      .eq('id', record.sender_id)
      .maybeSingle();

    const { data: tokens, error: tokenError } = await adminClient
      .from('user_fcm_tokens')
      .select('id, fcm_token')
      .eq('user_id', recipientId);

    if (tokenError || !tokens?.length) {
      return { sent: 0 };
    }

    const title = (sender?.name as string | undefined)?.trim() || 'Pesan baru';
    const body = this.buildBody(record);

    const response = await admin.messaging().sendEachForMulticast({
      tokens: tokens.map((t) => t.fcm_token as string),
      notification: { title, body },
      data: {
        type: 'chat',
        thread_id: record.thread_id,
        sender_id: record.sender_id,
        message_id: record.id,
      },
      android: { priority: 'high', notification: { sound: 'default' } },
      apns: {
        headers: { 'apns-priority': '10' },
        payload: { aps: { sound: 'default', badge: 1 } },
      },
    });

    const staleTokenIds: string[] = [];
    response.responses.forEach((res, index) => {
      if (res.success) return;
      const code = res.error?.code ?? '';
      if (
        code.includes('registration-token-not-registered') ||
        code.includes('invalid-registration-token')
      ) {
        staleTokenIds.push(tokens[index].id as string);
      }
    });

    if (staleTokenIds.length) {
      await adminClient
        .from('user_fcm_tokens')
        .delete()
        .in('id', staleTokenIds);
    }

    return { sent: response.successCount, failed: response.failureCount };
  }

  private buildBody(record: ChatMessageRecord): string {
    const text = record.message?.trim();
    if (text) return text;
    if (record.message_type === 'image') return 'Mengirim foto';
    return 'Pesan baru';
  }
}
