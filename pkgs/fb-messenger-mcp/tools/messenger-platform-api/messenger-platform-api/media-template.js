import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to send a media template message via the Messenger Platform API.
 *
 * @param {Object} args - Arguments for sending the media template message.
 * @param {string} args.pageScopedId - The page-scoped ID of the recipient.
 * @param {string} args.attachmentId - The attachment ID for the media.
 * @param {string} [args.version='v20.0'] - The version of the Messenger API to use.
 * @returns {Promise<Object>} - The result of the message sending operation.
 */
const executeFunction = async (args = {}) => {
  const { pageScopedId, attachmentId, version = 'v20.0' } = args;
  const baseUrl = 'https://graph.facebook.com';
  const token = getToken();
  const url = `${baseUrl}/${version}/${getPageId(args.pageId)}/messages`;
  
  const payload = {
    recipient: {
      id: pageScopedId
    },
    message: {
      attachment: {
        type: "template",
        payload: {
          template_type: "media",
          elements: [
            {
              media_type: "image",
              attachment_id: attachmentId,
              buttons: [
                {
                  type: "web_url",
                  url: "https://google.com",
                  title: "View Website"
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
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(payload)
    });

    if (!response.ok) {
      const errorData = await response.json();
      throw new Error(JSON.stringify(errorData));
    }

    const data = await response.json();
    return data;
  } catch (error) {
    console.error('Error sending media template message:', error);
    return {
      error: `An error occurred while sending the media template message: ${error instanceof Error ? error.message : JSON.stringify(error)}`
    };
  }
};

/**
 * Tool configuration for sending a media template message via the Messenger Platform API.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'send_media_template_message',
      description: 'Send a media template message via the Messenger Platform API.',
      parameters: {
        type: 'object',
        properties: {
          pageScopedId: {
            type: 'string',
            description: 'The page-scoped ID of the recipient.'
          },
          attachmentId: {
            type: 'string',
            description: 'The attachment ID for the media.'
          },
          version: {
            type: 'string',
            description: 'The version of the Messenger API to use.'
          }
        },
        required: ['pageScopedId', 'attachmentId']
      }
    }
  }
};

export { apiTool };