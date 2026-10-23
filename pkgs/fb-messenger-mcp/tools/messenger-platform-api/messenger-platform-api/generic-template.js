import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to send a generic template message via the Messenger Platform API.
 *
 * @param {Object} args - Arguments for sending the message.
 * @param {string} args.pageScopedId - The page-scoped ID of the recipient.
 * @param {string} [args.version='v22.0'] - The API version to use.
 * @returns {Promise<Object>} - The result of the message sending operation.
 */
const executeFunction = async (args = {}) => {
  const { pageScopedId, version = 'v22.0' } = args;
  const token = getToken();
  const url = `https://graph.facebook.com/${version}/${getPageId(args.pageId)}/messages`;
  
  const messageData = {
    recipient: {
      id: pageScopedId
    },
    message: {
      attachment: {
        type: "template",
        payload: {
          template_type: "generic",
          elements: [
            {
              title: "Welcome!",
              image_url: "https://raw.githubusercontent.com/fbsamples/original-coast-clothing/main/public/styles/male-work.jpg",
              subtitle: "We have the right hat for everyone.",
              default_action: {
                type: "web_url",
                url: "https://www.originalcoastclothing.com/",
                webview_height_ratio: "tall"
              },
              buttons: [
                {
                  type: "web_url",
                  url: "https://www.originalcoastclothing.com/",
                  title: "View Website"
                },
                {
                  type: "postback",
                  title: "Start Chatting",
                  payload: "DEVELOPER_DEFINED_PAYLOAD"
                }
              ]
            }
          ]
        }
      }
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
    console.error('Error sending message:', error);
    return {
      error: `An error occurred while sending the message: ${error instanceof Error ? error.message : JSON.stringify(error)}`
    };
  }
};

/**
 * Tool configuration for sending a generic template message via the Messenger Platform API.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'send_generic_template_message',
      description: 'Send a generic template message via the Messenger Platform API.',
      parameters: {
        type: 'object',
        properties: {
          pageScopedId: {
            type: 'string',
            description: 'The page-scoped ID of the recipient.'
          },
          version: {
            type: 'string',
            description: 'The API version to use.'
          }
        },
        required: ['pageScopedId']
      }
    }
  }
};

export { apiTool };