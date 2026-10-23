import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to send a receipt template message via the Messenger Platform API.
 *
 * @param {Object} args - Arguments for sending the message.
 * @param {string} args.pageId - The page-scoped ID of the recipient.
 * @param {string} args.version - The API version to use.
 * @param {string} args.recipientName - The name of the recipient.
 * @param {string} args.orderNumber - The order number for the receipt.
 * @param {string} args.currency - The currency for the transaction.
 * @param {string} args.paymentMethod - The payment method used.
 * @param {string} args.orderUrl - The URL for the order.
 * @param {string} args.timestamp - The timestamp of the order.
 * @param {Object} args.address - The address of the recipient.
 * @param {Array} args.elements - The items in the receipt.
 * @returns {Promise<Object>} - The result of the message sending operation.
 */
const executeFunction = async (args = {}) => {
  const { pageId, version, recipientName, orderNumber, currency, paymentMethod, orderUrl, timestamp, address, elements } = args;
  const token = getToken();
  const url = `https://graph.facebook.com/${version}/${getPageId(typeof pageId !== "undefined" ? pageId : args.pageId)}/messages`;

  const messageData = {
    recipient: {
      id: pageId,
    },
    message: {
      attachment: {
        type: "template",
        payload: {
          template_type: "receipt",
          recipient_name: recipientName,
          order_number: orderNumber,
          currency: currency,
          payment_method: paymentMethod,
          order_url: orderUrl,
          timestamp: timestamp,
          address: address,
          summary: {
            subtotal: 75.00,
            shipping_cost: 4.95,
            total_tax: 6.19,
            total_cost: 56.14,
          },
          adjustments: [
            {
              name: "New Customer Discount",
              amount: 20,
            },
            {
              name: "$10 Off Coupon",
              amount: 10,
            },
          ],
          elements: elements,
        },
      },
    },
  };

  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`,
      },
      body: JSON.stringify(messageData),
    });

    if (!response.ok) {
      const errorData = await response.json();
      throw new Error(JSON.stringify(errorData));
    }

    const data = await response.json();
    return data;
  } catch (error) {
    console.error('Error sending receipt template message:', error);
    return {
      error: `An error occurred while sending the message: ${error instanceof Error ? error.message : JSON.stringify(error)}`,
    };
  }
};

/**
 * Tool configuration for sending a receipt template message via the Messenger Platform API.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'send_receipt_template',
      description: 'Send a receipt template message via the Messenger Platform API.',
      parameters: {
        type: 'object',
        properties: {
          pageId: {
            type: 'string',
            description: 'The page-scoped ID of the recipient.'
          },
          version: {
            type: 'string',
            description: 'The API version to use.'
          },
          recipientName: {
            type: 'string',
            description: 'The name of the recipient.'
          },
          orderNumber: {
            type: 'string',
            description: 'The order number for the receipt.'
          },
          currency: {
            type: 'string',
            description: 'The currency for the transaction.'
          },
          paymentMethod: {
            type: 'string',
            description: 'The payment method used.'
          },
          orderUrl: {
            type: 'string',
            description: 'The URL for the order.'
          },
          timestamp: {
            type: 'string',
            description: 'The timestamp of the order.'
          },
          address: {
            type: 'object',
            description: 'The address of the recipient.'
          },
          elements: {
            type: 'array',
            description: 'The items in the receipt.'
          }
        },
        required: ['pageId', 'version', 'recipientName', 'orderNumber', 'currency', 'paymentMethod', 'orderUrl', 'timestamp', 'address', 'elements']
      }
    }
  }
};

export { apiTool };