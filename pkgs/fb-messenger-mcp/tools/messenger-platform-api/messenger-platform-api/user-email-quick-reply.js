import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to send a quick reply message via the Messenger Platform API.
 *
 * @param {Object} args - Arguments for the quick reply message.
 * @param {string} args.pageScopedId - The page-scoped ID of the recipient.
 * @param {string} [args.version='v22.0'] - The version of the Messenger API to use.
 * @returns {Promise<Object>} - The result of the quick reply message send operation.
 */
const executeFunction = async (args = {}) => {
  const { pageScopedId, version = 'v22.0' } = args;
  const baseUrl = 'https://graph.facebook.com';
  const token = getToken();

  const messageData = {
    recipient: {
      id: pageScopedId
    },
    messaging_type: "RESPONSE",
    message: {
      text: "Pick a color:",
      quick_replies: [
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
    const response = await fetch(`${baseUrl}/${version}/${getPageId(args.pageId)}/messages`, {
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
    console.error('Error sending quick reply message:', error);
    return {
      error: `An error occurred while sending the quick reply message: ${error instanceof Error ? error.message : JSON.stringify(error)}`
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
          version: {
            type: 'string',
            description: 'The version of the Messenger API to use.'
          }
        },
        required: ['pageScopedId']
      }
    }
  }
};

export { apiTool };