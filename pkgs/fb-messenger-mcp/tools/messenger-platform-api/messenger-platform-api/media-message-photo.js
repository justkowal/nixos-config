import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to send a media message (photo) via the Messenger Platform API.
 *
 * @param {Object} args - Arguments for sending the media message.
 * @param {string} args.pageScopedId - The Page-scoped ID of the recipient.
 * @param {string} args.imageUrl - The URL of the image to be sent.
 * @param {boolean} args.isReusable - Indicates if the image is reusable.
 * @returns {Promise<Object>} - The result of the media message send operation.
 */
const executeFunction = async (args = {}) => {
  const { pageScopedId, imageUrl, isReusable } = args;
  const baseUrl = 'https://graph.facebook.com';
  const version = 'v20.0'; // Specify the API version
  const token = getToken();
  const pageId = getPageId(args.pageId);

  try {
    // Construct the URL for the API request
    const url = `${baseUrl}/${version}/${getPageId(typeof pageId !== "undefined" ? pageId : args.pageId)}/messages`;

    // Create the message payload
    const payload = {
      recipient: {
        id: pageScopedId
      },
      message: {
        attachment: {
          type: 'image',
          payload: {
            url: imageUrl,
            is_reusable: isReusable
          }
        }
      }
    };

    // Set up headers for the request
    const headers = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`
    };

    // Perform the fetch request
    const response = await fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify(payload)
    });

    // Check if the response was successful
    if (!response.ok) {
      const errorData = await response.json();
      throw new Error(JSON.stringify(errorData));
    }

    // Parse and return the response data
    const data = await response.json();
    return data;
  } catch (error) {
    console.error('Error sending media message:', error);
    return {
      error: `An error occurred while sending the media message: ${error instanceof Error ? error.message : JSON.stringify(error)}`
    };
  }
};

/**
 * Tool configuration for sending media messages via the Messenger Platform API.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'send_media_message',
      description: 'Send a media message (photo) via the Messenger Platform API.',
      parameters: {
        type: 'object',
        properties: {
          pageScopedId: {
            type: 'string',
            description: 'The Page-scoped ID of the recipient.'
          },
          imageUrl: {
            type: 'string',
            description: 'The URL of the image to be sent.'
          },
          isReusable: {
            type: 'boolean',
            description: 'Indicates if the image is reusable.'
          }
        },
        required: ['pageScopedId', 'imageUrl', 'isReusable']
      }
    }
  }
};

export { apiTool };