import { Module } from '@nestjs/common';
import { ChatPushService } from './chat-push.service';
import { WebhooksController } from './webhooks.controller';

@Module({
  controllers: [WebhooksController],
  providers: [ChatPushService],
})
export class ChatPushModule {}
