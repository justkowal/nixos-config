import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to send a quick reply message via the Messenger Platform API.
 *
 * @param {Object} args - Arguments for sending the quick reply.
 * @param {string} args.pageScopedId - The page-scoped ID of the recipient.
 * @param {string} [args.messagingType="RESPONSE"] - The type of messaging to use.
 * @param {string} [args.text="Pick a color:"] - The text of the message to send.
 * @param {Array<Object>} [args.quickReplies] - An array of quick reply objects.
 * @returns {Promise<Object>} - The result of the message sending operation.
 */
const executeFunction = async (args = {}) => {
  const { pageScopedId, messagingType = 'RESPONSE', text = 'Pick a color:', quickReplies } = args;
  const version = 'v22.0'; // Set the API version
  const token = getToken();
  const pageId = getPageId(args.pageId);
  const url = `https://graph.facebook.com/${version}/${getPageId(typeof pageId !== "undefined" ? pageId : args.pageId)}/messages`;

  const messageData = {
    recipient: {
      id: pageScopedId
    },
    messaging_type: messagingType,
    message: {
      text: text,
      quick_replies: quickReplies || [
        {
          content_type: "text",
          title: "Red",
          payload: "{POSTBACK_PAYLOAD}",
          image_url: "http://example.com/img/red.png"
        },
        {
          content_type: "text",
          title: "Green",
          payload: "{POSTBACK_PAYLOAD}",
          image_url: "http://example.com/img/green.png"
        }
      ]
    }
  };

  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`
      },
      body: JSON.stringify(messageData)
    });

    if (!response.ok) {
      const errorData = await response.json();
      throw new Error(JSON.stringify(errorData));
    }

    const data = await response.json();
    return data;
  } catch (error) {
    console.error('Error sending quick reply:', error);
    return {
      error: `An error occurred while sending the quick reply: ${error instanceof Error ? error.message : JSON.stringify(error)}`
    };
  }
};

/**
 * Tool configuration for sending quick reply messages via the Messenger Platform API.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'send_quick_reply',
      description: 'Send a quick reply message via the Messenger Platform API.',
      parameters: {
        type: 'object',
        properties: {
          pageScopedId: {
            type: 'string',
            description: 'The page-scoped ID of the recipient.'
          },
          messagingType: {
            type: 'string',
            description: 'The type of messaging to use.'
          },
          text: {
            type: 'string',
            description: 'The text of the message to send.'
          },
          quickReplies: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                content_type: { type: 'string' },
                title: { type: 'string' },
                payload: { type: 'string' },
                image_url: { type: 'string' }
              },
              required: ['content_type', 'title', 'payload']
            },
            description: 'An array of quick reply objects.'
          }
        },
        required: ['pageScopedId']
      }
    }
  }
};

export { apiTool };