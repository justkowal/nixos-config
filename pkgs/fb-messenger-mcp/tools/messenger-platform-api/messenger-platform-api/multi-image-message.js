import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to send a multi-image message using the Messenger Platform API.
 *
 * @param {Object} args - Arguments for sending the message.
 * @param {string} args.pageScopedId - The Page-scoped ID of the recipient.
 * @param {Array<string>} args.imageUrls - An array of image URLs to be sent.
 * @returns {Promise<Object>} - The result of the message sending operation.
 */
const executeFunction = async (args = {}) => {
  const { pageScopedId, imageUrls } = args;
  const version = 'v22.0'; // API version
  const pageId = getPageId(args.pageId);
  const token = getToken();
  const url = `https://graph.facebook.com/${version}/${getPageId(typeof pageId !== "undefined" ? pageId : args.pageId)}/messages`;

  const messageData = {
    recipient: {
      id: pageScopedId
    },
    message: {
      attachments: imageUrls.map(url => ({
        type: 'image',
        payload: {
          url
        }
      }))
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
    console.error('Error sending multi-image message:', error);
    return {
      error: `An error occurred while sending the message: ${error instanceof Error ? error.message : JSON.stringify(error)}`
    };
  }
};

/**
 * Tool configuration for sending multi-image messages using the Messenger Platform API.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'send_multi_image_message',
      description: 'Send a multi-image message to a recipient on Messenger.',
      parameters: {
        type: 'object',
        properties: {
          pageScopedId: {
            type: 'string',
            description: 'The Page-scoped ID of the recipient.'
          },
          imageUrls: {
            type: 'array',
            items: {
              type: 'string',
              description: 'The URL of the image to send.'
            },
            description: 'An array of image URLs to be sent.'
          }
        },
        required: ['pageScopedId', 'imageUrls']
      }
    }
  }
};

export { apiTool };