import { Body, Controller, Headers, Post } from '@nestjs/common';
import {
  ChatMessageRecord,
  ChatPushService,
} from './chat-push.service';

type ChatWebhookBody = {
  record?: ChatMessageRecord;
};

@Controller('webhooks')
export class WebhooksController {
  constructor(private readonly chatPush: ChatPushService) {}

  @Post('chat-message')
  async onChatMessage(
    @Headers('x-webhook-secret') secret: string | undefined,
    @Body() body: ChatWebhookBody,
  ) {
    this.chatPush.verifyWebhookSecret(secret);

    const record = body.record;
    if (!record?.thread_id || !record.sender_id) {
      return { ok: true, skipped: true };
    }

    const result = await this.chatPush.sendForMessage(record);
    return { ok: true, ...result };
  }
}
